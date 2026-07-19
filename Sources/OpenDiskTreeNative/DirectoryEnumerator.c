#include "OpenDiskTreeNative.h"

#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int odt_append(ODTDirectoryListing *listing, size_t *capacity, const char *name, const struct stat *st) {
    size_t next_count = listing->count + 1;
    if (next_count > *capacity) {
        size_t next_capacity = *capacity == 0 ? 64 : *capacity * 2;
        ODTDirectoryEntry *next = realloc(listing->entries, next_capacity * sizeof(ODTDirectoryEntry));
        if (next == NULL) {
            return ENOMEM;
        }
        listing->entries = next;
        *capacity = next_capacity;
    }
    ODTDirectoryEntry *entry = &listing->entries[listing->count];
    memset(entry, 0, sizeof(*entry));
    entry->name = strdup(name);
    if (entry->name == NULL) {
        return ENOMEM;
    }
    entry->logical_size = st->st_size > 0 ? (uint64_t)st->st_size : 0;
    entry->allocated_size = st->st_blocks > 0 ? (uint64_t)st->st_blocks * 512ULL : 0;
    entry->file_id = (uint64_t)st->st_ino;
    entry->device_id = (uint64_t)st->st_dev;
    entry->created_seconds = st->st_birthtimespec.tv_sec;
    entry->modified_seconds = st->st_mtimespec.tv_sec;
    entry->mode = st->st_mode;
    entry->link_count = st->st_nlink;
    entry->is_hidden = name[0] == '.';
    listing->count = next_count;
    return 0;
}

static int odt_read_fallback(int fd, ODTDirectoryListing *listing, size_t *capacity) {
    int duplicate = dup(fd);
    if (duplicate < 0) {
        return errno;
    }
    DIR *directory = fdopendir(duplicate);
    if (directory == NULL) {
        int error = errno;
        close(duplicate);
        return error;
    }

    struct dirent *dir_entry;
    while ((dir_entry = readdir(directory)) != NULL) {
        if (strcmp(dir_entry->d_name, ".") == 0 || strcmp(dir_entry->d_name, "..") == 0) {
            continue;
        }
        struct stat st;
        if (fstatat(fd, dir_entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            continue;
        }
        int error = odt_append(listing, capacity, dir_entry->d_name, &st);
        if (error != 0) {
            closedir(directory);
            return error;
        }
    }
    closedir(directory);
    return 0;
}

ODTDirectoryListing odt_read_directory(const char *path) {
    ODTDirectoryListing listing;
    memset(&listing, 0, sizeof(listing));

    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        listing.error_code = errno;
        return listing;
    }

    struct attrlist attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME;

    char buffer[64 * 1024];
    size_t capacity = 0;
    int bulk_failed = 0;
    for (;;) {
        int count = getattrlistbulk(fd, &attributes, buffer, sizeof(buffer), FSOPT_PACK_INVAL_ATTRS);
        if (count == 0) {
            break;
        }
        if (count < 0) {
            bulk_failed = 1;
            break;
        }
        listing.used_bulk_api = 1;
        char *cursor = buffer;
        for (int index = 0; index < count; index++) {
            uint32_t record_length = 0;
            memcpy(&record_length, cursor, sizeof(record_length));
            if (record_length < sizeof(uint32_t) + sizeof(attribute_set_t) + sizeof(attrreference_t)) {
                bulk_failed = 1;
                break;
            }

            char *field = cursor + sizeof(uint32_t) + sizeof(attribute_set_t);
            attrreference_t name_reference;
            memcpy(&name_reference, field, sizeof(name_reference));
            const char *name = field + name_reference.attr_dataoffset;
            if (name_reference.attr_length > 0 && name[0] != '\0') {
                struct stat st;
                if (fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
                    int error = odt_append(&listing, &capacity, name, &st);
                    if (error != 0) {
                        listing.error_code = error;
                        close(fd);
                        return listing;
                    }
                }
            }
            cursor += record_length;
        }
        if (bulk_failed) {
            break;
        }
    }

    if (bulk_failed) {
        if (listing.count == 0) {
            lseek(fd, 0, SEEK_SET);
            listing.used_bulk_api = 0;
            listing.error_code = odt_read_fallback(fd, &listing, &capacity);
        } else {
            listing.error_code = errno != 0 ? errno : EIO;
        }
    }

    close(fd);
    return listing;
}

void odt_free_directory_listing(ODTDirectoryListing listing) {
    for (size_t index = 0; index < listing.count; index++) {
        free(listing.entries[index].name);
    }
    free(listing.entries);
}

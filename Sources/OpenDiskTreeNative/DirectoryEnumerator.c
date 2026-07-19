#include "OpenDiskTreeNative.h"

#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vnode.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int odt_append(ODTDirectoryListing *listing, size_t *capacity, const char *name, const struct stat *st, int is_mount_point) {
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
    entry->is_mount_point = is_mount_point != 0;
    listing->count = next_count;
    return 0;
}

static void odt_clear(ODTDirectoryListing *listing, size_t *capacity) {
    for (size_t index = 0; index < listing->count; index++) {
        free(listing->entries[index].name);
    }
    free(listing->entries);
    listing->entries = NULL;
    listing->count = 0;
    *capacity = 0;
}

static int odt_read_field(char **field, const char *end, void *value, size_t size) {
    if (*field > end || size > (size_t)(end - *field)) {
        return EIO;
    }
    memcpy(value, *field, size);
    *field += size;
    return 0;
}

static mode_t odt_mode_for_type(fsobj_type_t type) {
    switch (type) {
        case VREG: return S_IFREG;
        case VDIR: return S_IFDIR;
        case VLNK: return S_IFLNK;
        case VBLK: return S_IFBLK;
        case VCHR: return S_IFCHR;
        case VSOCK: return S_IFSOCK;
        case VFIFO: return S_IFIFO;
        default: return 0;
    }
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
        int error = odt_append(listing, capacity, dir_entry->d_name, &st, 0);
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
    attributes.commonattr =
        ATTR_CMN_RETURNED_ATTRS |
        ATTR_CMN_ERROR |
        ATTR_CMN_NAME |
        ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE |
        ATTR_CMN_CRTIME |
        ATTR_CMN_MODTIME |
        ATTR_CMN_FILEID;
    attributes.dirattr = ATTR_DIR_MOUNTSTATUS;
    attributes.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;

    char buffer[64 * 1024];
    size_t capacity = 0;
    int bulk_failed = 0;
    for (;;) {
        int count = getattrlistbulk(
            fd,
            &attributes,
            buffer,
            sizeof(buffer),
            FSOPT_PACK_INVAL_ATTRS
        );
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
            char *record_start = cursor;
            char *buffer_end = buffer + sizeof(buffer);
            uint32_t record_length = 0;
            if (odt_read_field(&cursor, buffer_end, &record_length, sizeof(record_length)) != 0 ||
                record_length < sizeof(uint32_t) + sizeof(attribute_set_t) + sizeof(attrreference_t) ||
                record_length > (uint32_t)(buffer_end - record_start)) {
                bulk_failed = 1;
                break;
            }
            char *record_end = record_start + record_length;
            char *field = cursor;
            attribute_set_t returned;
            uint32_t entry_error = 0;
            attrreference_t name_reference;
            char *name_field = NULL;
            dev_t device_id = 0;
            fsobj_type_t object_type = VNON;
            struct timespec created = {0};
            struct timespec modified = {0};
            uint64_t file_id = 0;
            uint32_t mount_status = 0;
            uint32_t link_count = 0;
            off_t logical_size = 0;
            off_t allocated_size = 0;

            if (odt_read_field(&field, record_end, &returned, sizeof(returned)) != 0 ||
                odt_read_field(&field, record_end, &entry_error, sizeof(entry_error)) != 0) {
                bulk_failed = 1;
                break;
            }
            name_field = field;
            if (odt_read_field(&field, record_end, &name_reference, sizeof(name_reference)) != 0 ||
                odt_read_field(&field, record_end, &device_id, sizeof(device_id)) != 0 ||
                odt_read_field(&field, record_end, &object_type, sizeof(object_type)) != 0 ||
                odt_read_field(&field, record_end, &created, sizeof(created)) != 0 ||
                odt_read_field(&field, record_end, &modified, sizeof(modified)) != 0 ||
                odt_read_field(&field, record_end, &file_id, sizeof(file_id)) != 0) {
                bulk_failed = 1;
                break;
            }
            if ((returned.dirattr & ATTR_DIR_MOUNTSTATUS) != 0 &&
                odt_read_field(&field, record_end, &mount_status, sizeof(mount_status)) != 0) {
                bulk_failed = 1;
                break;
            }
            if ((returned.fileattr & ATTR_FILE_LINKCOUNT) != 0 &&
                odt_read_field(&field, record_end, &link_count, sizeof(link_count)) != 0) {
                bulk_failed = 1;
                break;
            }
            if ((returned.fileattr & ATTR_FILE_TOTALSIZE) != 0 &&
                odt_read_field(&field, record_end, &logical_size, sizeof(logical_size)) != 0) {
                bulk_failed = 1;
                break;
            }
            if ((returned.fileattr & ATTR_FILE_ALLOCSIZE) != 0 &&
                odt_read_field(&field, record_end, &allocated_size, sizeof(allocated_size)) != 0) {
                bulk_failed = 1;
                break;
            }

            const char *name = name_field + name_reference.attr_dataoffset;
            if (name_reference.attr_length == 0 || name < record_start || name >= record_end ||
                name_reference.attr_length > (uint32_t)(record_end - name) ||
                memchr(name, '\0', name_reference.attr_length) == NULL) {
                bulk_failed = 1;
                break;
            }
            if (name[0] == '\0') {
                cursor = record_end;
                continue;
            }

            const attrgroup_t required_common =
                ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
            const attrgroup_t required_file =
                ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
            int needs_stat = entry_error != 0 ||
                (returned.commonattr & required_common) != required_common ||
                ((object_type == VREG || object_type == VLNK) &&
                 (returned.fileattr & required_file) != required_file);

            struct stat st;
            memset(&st, 0, sizeof(st));
            if (needs_stat) {
                if (fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                    cursor = record_end;
                    continue;
                }
            } else {
                st.st_dev = device_id;
                st.st_ino = file_id;
                st.st_mode = odt_mode_for_type(object_type);
                st.st_nlink = link_count > 0 ? link_count : 1;
                st.st_size = logical_size > 0 ? logical_size : 0;
                st.st_blocks = allocated_size > 0 ? (allocated_size + 511) / 512 : 0;
                st.st_birthtimespec = created;
                st.st_mtimespec = modified;
            }

            int error = odt_append(
                &listing,
                &capacity,
                name,
                &st,
                (returned.dirattr & ATTR_DIR_MOUNTSTATUS) != 0 &&
                    (mount_status & DIR_MNTSTATUS_MNTPOINT) != 0
            );
            if (error != 0) {
                listing.error_code = error;
                close(fd);
                return listing;
            }
            cursor = record_end;
        }
        if (bulk_failed) {
            break;
        }
    }

    if (bulk_failed) {
        odt_clear(&listing, &capacity);
        lseek(fd, 0, SEEK_SET);
        listing.used_bulk_api = 0;
        listing.error_code = odt_read_fallback(fd, &listing, &capacity);
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

#ifndef OPEN_DISK_TREE_NATIVE_H
#define OPEN_DISK_TREE_NATIVE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *name;
    uint64_t logical_size;
    uint64_t allocated_size;
    uint64_t file_id;
    uint64_t device_id;
    int64_t created_seconds;
    int64_t modified_seconds;
    uint32_t mode;
    uint32_t link_count;
    uint8_t is_hidden;
} ODTDirectoryEntry;

typedef struct {
    ODTDirectoryEntry *entries;
    size_t count;
    int used_bulk_api;
    int error_code;
} ODTDirectoryListing;

ODTDirectoryListing odt_read_directory(const char *path);
void odt_free_directory_listing(ODTDirectoryListing listing);

#ifdef __cplusplus
}
#endif

#endif

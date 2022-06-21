#ifndef ILBAR_CACHE_H
#define ILBAR_CACHE_H

#include <stdbool.h>
#include <stddef.h>
#include <wayland-util.h>

/** An entry in the cache. */
typedef struct {
    /** A linked list of entries, most recent first */
    struct wl_list link;
    /** The data in the cache. */
    void *key, *value;
} CacheEntry;

/** Callbacks for handling generic cache entries. No NULL callbacks. */
typedef struct {
    /** Get the hash value of a key. */
    size_t (*hash)(const void *key);
    /** Compare two keys. */
    bool (*equal)(const void *a, const void *b);
    /** Free resources held by an entry. */
    void (*free)(const CacheEntry *entry);
} CacheCallbacks;

/** A generic hashtable cache. */
typedef struct {
    /** The number of entries allocated. */
    size_t size;
    /** The number of entries used. */
    size_t load;
    /** The entries in the cache. */
    CacheEntry *entries;
    /** The used entries in the cache, sorted by most recently used */
    struct wl_list recent;
    /** Callbacks for handling the generic data. */
    const CacheCallbacks *callbacks;
} Cache;

/** Create a new cache. */
Cache *cache_init(size_t size, const CacheCallbacks *callbacks);

/** Destroy the cache and related resources. */
void cache_deinit(Cache *cache);

/** Get the value for a given key, or NULL if not present. */
void *cache_get(Cache *cache, const void *key);

/** Store the given key and value into the cache. */
void cache_put(Cache *cache, void *key, void *value);

#endif

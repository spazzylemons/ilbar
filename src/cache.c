#include <stdlib.h>
#include <string.h>

#include <stdio.h>

#include "cache.h"

Cache *cache_init(size_t size, const CacheCallbacks *callbacks) {
    Cache *cache = malloc(sizeof(Cache));
    if (!cache) return NULL;

    cache->entries = malloc(sizeof(CacheEntry) * size);
    if (!cache->entries) {
        free(cache);
        return NULL;
    }

    cache->size = size;
    cache->load = 0;
    wl_list_init(&cache->recent);
    for (size_t i = 0; i < size; ++i) {
        cache->entries[i].key = NULL;
    }
    cache->callbacks = callbacks;

    return cache;
}

void cache_deinit(Cache *cache) {
    for (size_t i = 0; i < cache->size; ++i) {
        const CacheEntry *entry = &cache->entries[i];
        if (entry->key) cache->callbacks->free(entry);
    }
    free(cache->entries);
    free(cache);
}

void *cache_get(Cache *cache, const void *key) {
    size_t hash = cache->callbacks->hash(key);
    size_t index = hash % cache->size;
    for (;;) {
        CacheEntry *entry = &cache->entries[index];
        if (!entry->key) return NULL;
        if (cache->callbacks->equal(key, entry->key)) {
            /* move entry to head of recently used */
            wl_list_remove(&entry->link);
            wl_list_insert(&cache->recent, &entry->link);
            return entry->value;
        }
        index = (index + 1) % cache->size;
    }
}

void cache_put(Cache *cache, void *key, void *value) {
    /* need at least one free space always available */
    if (cache->load + 1 == cache->size) {
        /* get least recently used */
        CacheEntry *last =
            wl_container_of(cache->recent.prev, last, link);
        /* free its contents */
        cache->callbacks->free(last);
        if (!wl_list_empty(&last->link)) {
            wl_list_remove(&last->link);
            wl_list_init(&last->link);
        }
        /* shift over rest of chain */
        size_t index = last - cache->entries;
        for (;;) {
            size_t next = (index + 1) % cache->size;
            cache->entries[index].key = cache->entries[next].key;
            cache->entries[index].value = cache->entries[next].value;
            if (!cache->entries[next].key) {
                if (!wl_list_empty(&cache->entries[index].link)) {
                    wl_list_remove(&cache->entries[index].link);
                    wl_list_init(&cache->entries[index].link);
                }
                break;
            }
            index = next;
        }
        /** free up space */
        --cache->load;
    }
    /* find a spot to put the new element */
    size_t hash = cache->callbacks->hash(key);
    size_t index = hash % cache->size;
    for (;;) {
        CacheEntry *entry = &cache->entries[index];
        if (!entry->key) {
            /* use the unused entry */
            entry->key = key;
            entry->value = value;
            wl_list_insert(&cache->recent, &entry->link);
            ++cache->load;
            return;
        }
        if (cache->callbacks->equal(key, entry->key)) {
            /* move entry to head of recently used */
            wl_list_remove(&entry->link);
            wl_list_insert(&cache->recent, &entry->link);
            /* free the old value */
            cache->callbacks->free(entry);
            /* put in the new value */
            entry->key = key;
            entry->value = value;
            return;
        }
        index = (index + 1) % cache->size;
    }
}

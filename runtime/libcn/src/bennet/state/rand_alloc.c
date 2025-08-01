#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <bennet/internals/domain.h>
#include <bennet/internals/rand.h>
#include <bennet/state/rand_alloc.h>
#include <bennet/utils/vector.h>

// Struct to represent an allocated region
typedef struct {
  size_t offset;
  size_t length;
} rand_alloc_region;

BENNET_VECTOR_DECL(rand_alloc_region)
BENNET_VECTOR_IMPL(rand_alloc_region)

// Struct for the allocator
typedef struct {
  char *buffer;
  size_t buffer_len;
  bennet_vector(rand_alloc_region) regions;
} rand_alloc;

// Add a static buffer for the random allocator
#define RAND_ALLOC_MEM_SIZE (1024 * 1024 * 16)
static rand_alloc global_rand_alloc;

// Initialize the allocator
static void bennet_rand_alloc_init() {
  if (global_rand_alloc.buffer != NULL) {
    return;
  }

  global_rand_alloc.buffer = malloc(RAND_ALLOC_MEM_SIZE);
  global_rand_alloc.buffer_len = RAND_ALLOC_MEM_SIZE;
  bennet_vector_init(rand_alloc_region)(&global_rand_alloc.regions);
}

// Helper: check if a region overlaps with any allocated region
static bool overlaps(size_t offset, size_t length) {
  size_t end = offset + length;
  for (size_t i = 0; i < global_rand_alloc.regions.size; ++i) {
    size_t r_start = global_rand_alloc.regions.data[i].offset;
    size_t r_end = r_start + global_rand_alloc.regions.data[i].length;
    if (!(end <= r_start || offset >= r_end)) {
      return true;
    }
  }
  return false;
}

// Allocate a random, non-overlapping region
void *bennet_rand_alloc(size_t length) {
  bennet_rand_alloc_init();

  if (length == 0 || length > global_rand_alloc.buffer_len) {
    return NULL;
  }
  const int max_attempts = 100;
  for (int attempt = 0; attempt < max_attempts; ++attempt) {
    size_t max_offset = global_rand_alloc.buffer_len - length;
    size_t offset = (size_t)(bennet_uniform_uint64_t(max_offset + 1));
    if (!overlaps(offset, length)) {
      rand_alloc_region region = {offset, length};
      bennet_vector_push(rand_alloc_region)(&global_rand_alloc.regions, region);
      return global_rand_alloc.buffer + offset;
    }
  }

  // No available region found
  cn_failure(CN_FAILURE_ALLOC, NON_SPEC);
  return NULL;
}

// Free the allocator
void bennet_rand_alloc_free_all(void) {
  bennet_vector_free(rand_alloc_region)(&global_rand_alloc.regions);
}

// Returns the minimum pointer that can be generated by the allocator
void *bennet_rand_alloc_min_ptr(void) {
  bennet_rand_alloc_init();

  return global_rand_alloc.buffer;
}

// Returns the maximum (inclusive) pointer that can be generated by the allocator
void *bennet_rand_alloc_max_ptr(void) {
  bennet_rand_alloc_init();

  return global_rand_alloc.buffer + global_rand_alloc.buffer_len - 1;
}

// Allocate a random, non-overlapping region of the given length within [lower, upper] (inclusive bounds)
void *bennet_rand_alloc_bounded(bennet_domain(uintptr_t) * cs) {
  bennet_rand_alloc_init();

  size_t bytes = cs->lower_offset_bound + cs->upper_offset_bound;

  assert(bytes != 0);

  char *buf_start = global_rand_alloc.buffer;
  char *buf_end = global_rand_alloc.buffer + global_rand_alloc.buffer_len - 1;

  char *low = (char *)bennet_optional_unwrap_or(uintptr_t)(
      &cs->lower_bound_inc, (uintptr_t)buf_start);
  char *high = (char *)bennet_optional_unwrap_or(uintptr_t)(
      &cs->upper_bound_inc, (uintptr_t)buf_end);
  assert(low <= high);

  size_t min_offset = (size_t)(low - buf_start);
  size_t max_offset = (size_t)(high - buf_start);  // Inclusive
  size_t available_bytes = max_offset - min_offset + 1;
  if (max_offset < min_offset || available_bytes < bytes) {
    cn_failure(CN_FAILURE_ALLOC, NON_SPEC);
    return NULL;
  }

  size_t range = available_bytes - bytes + 1;  // Exclusive
  const int max_attempts = 100;
  for (int attempt = 0; attempt < max_attempts; ++attempt) {
    size_t raw_offset = min_offset + (size_t)(bennet_uniform_uint32_t(range));

    // Align the offset
    size_t alignment =
        bennet_optional_unwrap_or(uintptr_t)(&cs->multiple, alignof(max_align_t));
    size_t aligned_offset = (raw_offset + (alignment - 1)) & ~(alignment - 1);

    // Check if aligned_offset is still within bounds
    if (aligned_offset < min_offset || max_offset < aligned_offset ||
        max_offset < (aligned_offset + bytes - 1)) {
      continue;
    }

    if (!overlaps(aligned_offset, bytes)) {
      rand_alloc_region region = {aligned_offset, bytes};
      bennet_vector_push(rand_alloc_region)(&global_rand_alloc.regions, region);
      return global_rand_alloc.buffer + aligned_offset;
    }
  }

  // No available region found
  cn_failure(CN_FAILURE_ALLOC, NON_SPEC);
  return NULL;
}

// Free a single region given a pointer to its start
void bennet_rand_alloc_free(void *ptr) {
  if (ptr == NULL) {
    return;
  }

  assert(global_rand_alloc.buffer != NULL);

  size_t offset = (char *)ptr - global_rand_alloc.buffer;
  for (size_t i = 0; i < global_rand_alloc.regions.size; ++i) {
    if (global_rand_alloc.regions.data[i].offset == offset) {
      bennet_vector_delete(rand_alloc_region)(&global_rand_alloc.regions, i);
      return;
    }
  }
}

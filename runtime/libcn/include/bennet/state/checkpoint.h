#ifndef BENNET_CHECKPOINT_H
#define BENNET_CHECKPOINT_H

#include <bennet/internals/rand.h>
#include <bennet/state/alloc.h>
#include <cn-executable/bump_alloc.h>

typedef struct {
  cn_bump_frame_id frame_id;
  size_t alloc;
  size_t ownership;
} bennet_checkpoint;

static inline bennet_checkpoint bennet_checkpoint_save(void) {
  return (bennet_checkpoint){
      .frame_id = cn_bump_get_frame_id(),
      .alloc = bennet_alloc_save(),
      .ownership = bennet_ownership_save(),
  };
}

static inline void bennet_checkpoint_restore(const bennet_checkpoint* cp) {
  cn_bump_free_after(cp->frame_id);
  bennet_alloc_restore(cp->alloc);
  bennet_ownership_restore(cp->ownership);
}

#endif  // BENNET_CHECKPOINT_H

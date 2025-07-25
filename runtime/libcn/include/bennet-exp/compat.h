#ifndef BENNET_EXP_COMPAT_H
#define BENNET_EXP_COMPAT_H

#include <stdint.h>

#include <bennet-exp/internals/rand.h>
#include <bennet-exp/state/failure.h>

#define BENNET_BACKTRACK_NONE BENNET_FAILURE_NONE

#define BENNET_BACKTRACK_TIMEOUT BENNET_FAILURE_TIMEOUT

#endif  // BENNET_EXP_COMPAT_H

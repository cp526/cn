#!/usr/bin/env bash
set -euo pipefail -o noclobber

# set -xv # uncomment for debugging

function echo_and_err() {
    printf "$1\n"
    exit 1
}

[ $# -eq 0 ] || echo_and_err "USAGE: $0"

RUNTIME_PREFIX="$OPAM_SWITCH_PREFIX/lib/cn/runtime"
[ -d "${RUNTIME_PREFIX}" ] || echo_and_err "Could not find CN's runtime directory (looked at: '${RUNTIME_PREFIX}')"

CHECK_SCRIPT="${RUNTIME_PREFIX}/libexec/cn-runtime-single-file.sh"

[ -f "${CHECK_SCRIPT}" ] || echo_and_err "Could not find single file helper script: ${CHECK_SCRIPT}"

SCRIPT_OPT="-qu"

function exits_with_code() {
  local file=$1
  local expected_exit_code=$2

  if ! [ -f "$1" ]; then
    printf "\033[31mFAIL\033[0m (file '$1' does not exist)\n"
    return 1
  fi
  printf "[$file]... "
  OUTPUT=$(timeout 40 "${CHECK_SCRIPT}" "${SCRIPT_OPT}" "$file" 2>&1)
  local result=$?

  if [ $result -eq $expected_exit_code ]; then
    printf "\033[32mPASS\033[0m\n"
    return 0
  else
    printf "\033[31mFAIL\033[0m (Unexpected return code: $result expected: $expected_exit_code)\n${OUTPUT}\n"
    return 1
  fi
}


SUCCESS=$(find cn -name '*.c' \
    ! -name "*.error.c"  \
    ! -path '*/multifile/*' \
    ! -path '*/mutual_rec/*' \
    ! -path '*/tree16/*' \
    ! -path "cn/accesses_on_spec/clientfile.c" \
    ! -name "division_casting.c" \
    ! -name "b_or.c" \
    ! -name "mod_with_constants.c" \
    ! -name "inconsistent.c" \
    ! -name "forloop_with_decl.c" \
    ! -path "tree16/as_partial_map/tree16.c" \
    ! -path "tree16/as_mutual_dt/tree16.c" \
    ! -name "mod.c" \
    ! -name "mod_precedence.c" \
    ! -name "fun_ptr_three_opts.c" \
    ! -name "inconsistent2.c" \
    ! -name "block_type.c" \
    ! -name "division_with_constants.c" \
    ! -name "division.c" \
    ! -name "get_from_arr.c" \
    ! -name "implies.c" \
    ! -name "split_case.c" \
    ! -name "mod_casting.c" \
    ! -name "arrow_access.c" \
    ! -name "tag_defs.c" \
    ! -name "cn_inline.c" \
    ! -path "mutual_rec/mutual_rec.c" \
    ! -name "get_from_array.c" \
    ! -name "ownership_at_negative_index.c" \
    ! -name "fun_addrs_cn_stmt.c" \
    ! -name "division_precedence.c" \
    ! -name "implies_associativity.c" \
    ! -name "pred_def04.c" \
    ! -name "implies_precedence.c" \
    ! -name "fun_ptr_extern.c" \
    ! -name "b_xor.c" \
    ! -name "copy_alloc_id.c" \
    ! -name "copy_alloc_id.error.c" \
    ! -name "copy_alloc_id2.error.c" \
    ! -name "has_alloc_id.c" \
    ! -name "has_alloc_id_shift.c" \
    ! -name "ptr_diff2.c" \
    ! -name "has_alloc_id_ptr_neq.c" \
    ! -name "spec_null_shift.c" \
    ! -name "alloc_token.c" \
    ! -name "ptr_diff.c" \
    ! -name "mask_ptr.c" \
    ! -name "previously_inconsistent_assumptions1.c" \
    ! -name "previously_inconsistent_assumptions2.c" \
    ! -name "ptr_relop.c" \
    ! -name "ptr_relop.error.c" \
    ! -name "int_to_ptr.c" \
    ! -name "int_to_ptr.error.c" \
    ! -name "create_rdonly.c" \
    ! -name "offsetof_int_const.c" \
    ! -name "issue_113.c" \
    ! -name "alloc_create.c" \
    ! -name "ghost_arguments.c" \
    ! -name "to_from_bytes_block.c" \
)

# Include files which cause error for proof but not testing
SUCCESS+=("cn/merging_arrays.error.c" "cn/pointer_to_char_cast.error.c" "cn/pointer_to_unsigned_int_cast.error.c")

NO_MAIN="\
       cn/b_or.c \
       cn/division_casting.c \
       cn/mod_with_constants.c \
       cn/tree16/as_partial_map/tree16.c \
       cn/tree16/as_mutual_dt/tree16.c \
       cn/mod.c \
       cn/mod_precedence.c \
       cn/multifile/g.c \
       cn/multifile/f.c \
       cn/block_type.c \
       cn/division_with_constants.c \
       cn/division.c \
       cn/implies.c \
       cn/mod_casting.c \
       cn/arrow_access.c \
       cn/division_precedence.c \
       cn/implies_associativity.c \
       cn/implies_precedence.c \
       cn/b_xor.c \
       cn/previously_inconsistent_assumptions1.c \
       cn/previously_inconsistent_assumptions2.c \
       cn/issue_113.c \
       "

BUGGY="\
       cn/forloop_with_decl.c \
       cn/fun_ptr_three_opts.c \
       cn/get_from_arr.c \
       cn/split_case.c \
       cn/tag_defs.c \
       cn/cn_inline.c \
       cn/mutual_rec/mutual_rec*.c \
       cn/get_from_array.c \
       cn/ownership_at_negative_index.c \
       cn/fun_addrs_cn_stmt.c \
       cn/pred_def04.c \
       cn/fun_ptr_extern.c \
       cn/copy_alloc_id.c \
       cn/copy_alloc_id.error.c \
       cn/copy_alloc_id2.error.c \
       cn/has_alloc_id.c \
       cn/has_alloc_id_shift.c \
       cn/ptr_diff2.c \
       cn/has_alloc_id_ptr_neq.c \
       cn/spec_null_shift.c \
       cn/alloc_token.c \
       cn/ptr_diff.c \
       cn/mask_ptr.c \
       cn/ptr_relop.c \
       cn/ptr_relop.error.c \
       cn/int_to_ptr.c \
       cn/int_to_ptr.error.c \
       cn/create_rdonly.c \
       cn/offsetof_int_const.c \
       cn/accesses_on_spec/clientfile.c \
       cn/alloc_create.c \
       cn/ghost_arguments.c \
       cn/to_from_bytes_block.c \
       "

# Exclude files which cause error for proof but not testing
SHOULD_FAIL=$(find cn -name '*.error.c' \
  ! -name "merging_arrays.error.c" \
  ! -name "pointer_to_char_cast.error.c" \
  ! -name "pointer_to_unsigned_int_cast.error.c" \
  ! -name "ptr_diff2.error.c" \
  ! -name "to_bytes.error.c" \
  ! -name "before_from_bytes.error.c" \
  ! -name "partial_init_bytes.error.c" \
  ! -name "before_to_bytes.error.c" \
)

FAILED=""

for FILE in ${SUCCESS[@]}; do
  if ! exits_with_code "${FILE}" 0; then
    FAILED+=" ${FILE}"
  fi
done

for FILE in ${SHOULD_FAIL}; do
  if ! exits_with_code "${FILE}" 1; then
    FAILED+=" ${FILE}"
  fi
done

for FILE in ${NO_MAIN}; do
  if ! exits_with_code "${FILE}" 1; then
    FAILED+=" ${FILE}"
  fi
done

for FILE in ${BUGGY}; do
  if ! exits_with_code "${FILE}" 1; then
    FAILED+=" ${FILE}"
  fi
done

if [ -z "${FAILED}" ]; then
  exit 0
else
  printf "\033[31mFAILED: ${FAILED}\033[0m\n"
  exit 1
fi


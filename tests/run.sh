#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pymove-tests.XXXXXX")
export XDG_STATE_HOME="$run_dir/state"
export XDG_CACHE_HOME="$run_dir/cache"
export NVIM_LOG_FILE="$run_dir/nvim.log"
printf 'Test logs: %s\n' "$run_dir"
cd "$repo_dir"
exec "${NVIM:-nvim}" -u NONE -i NONE -n -l tests/run.lua "$@"

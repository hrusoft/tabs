#!/bin/bash
# `make check`: its steps side by side where they can be. Lint runs beside the
# build. Then the tests run beside the warnings check, the packaging gate and
# the scaffold check. The gate and the scaffold run at a lower priority, so they
# take only what the tests leave: the tests take longest, and a test starved of
# CPU can miss a wait.
#
# The build and the tests print as they go; every other step prints in one
# piece when it's done (build/check/<step>.log). Every step runs to the end
# unless the build fails (nothing to test then), and the check fails if any did.
#
# Usage: CONFIG=Debug Scripts/check.sh [lanes]   (make check passes CONFIG and LANES)
set -o pipefail
cd "$(dirname "$0")/.."
lanes=${1:-4}
config=${CONFIG:-Debug}
logs=build/check
rm -rf "$logs"
mkdir -p "$logs"
failed=()
names=()
pids=()

# start <step> <command…>: runs it in the background, into its log.
start() {
    local name=$1
    shift
    "$@" > "$logs/$name.log" 2>&1 &
    pids+=("$!")
    names+=("$name")
}

# Waits for every started step and prints its log.
finish() {
    local index
    for index in "${!pids[@]}"; do
        if ! wait "${pids[$index]}"; then failed+=("${names[$index]}"); fi
        echo "--- ${names[$index]}"
        cat "$logs/${names[$index]}.log"
    done
    names=()
    pids=()
}

# run <step> <command…>: in the foreground, printing as it goes.
run() {
    local name=$1
    shift
    if ! "$@"; then failed+=("$name"); fi
}

start lint make lint
run build make CONFIG="$config" build-tests
finish
if [[ " ${failed[*]} " == *" build "* ]]; then
    echo "check: the build failed; nothing to test"
    exit 1
fi

# What `make warnings` reads, without building again: a build beside the tests would rewrite
# what they run.
start warnings env CONFIG="$config" Scripts/check-warnings.py build/build-tests.log
start verify nice -n 10 make CONFIG="$config" verify-built
start scaffold nice -n 10 make CONFIG="$config" check-scaffold
run test Scripts/test-lanes.py --lanes "$lanes"
finish

if ((${#failed[@]})); then
    echo "check: failed: ${failed[*]}"
    exit 1
fi
echo "check: lint, warnings, every test, the packaging gate and the scaffold passed"

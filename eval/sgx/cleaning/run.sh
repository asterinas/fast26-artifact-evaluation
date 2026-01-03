#!/bin/bash
set -euo pipefail

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOMFILE="${SCRIPT_DIR}/cleaning.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"

# Tunables (override via env): GiB sizes keep parity with cleaning.cpp defaults.

DISK_PATH=${DISK_PATH:-/dev/sworndisk}
TOTAL_GB=${TOTAL_GB:-50}
BATCH_GB=${BATCH_GB:-5}
USED_RATE=${USED_RATE:-0.8}
LOOP_TIMES=${LOOP_TIMES:-10}
INTERVAL_SEC=${INTERVAL_SEC:-30}
DISK_SIZE=${DISK_SIZE:-60GB}

compile_cleaning() {
    echo -e "${YELLOW}Compiling cleaning benchmark...${NC}" >&2
    cd "${SCRIPT_DIR}"
    g++ cleaning.cpp -std=c++17 -O2 -Wall -Wextra -o cleaning
}

init_occlum_instance() {
    echo -e "${YELLOW}Initializing Occlum instance...${NC}" >&2
    cd "${SCRIPT_DIR}"
    rm -rf occlum_instance && occlum new occlum_instance >&2
    cd occlum_instance

    TCS_NUM=$(($(nproc) * 2))
    new_json="$(jq --argjson THREAD_NUM "${TCS_NUM}" --arg DISK_NAME "sworndisk" --arg DISK_SIZE "${DISK_SIZE}" '
        .resource_limits.user_space_size="2000MB" |
        .resource_limits.user_space_max_size="2000MB" |
        .resource_limits.kernel_space_heap_size="3000MB" |
        .resource_limits.kernel_space_heap_max_size="3000MB" |
        .resource_limits.max_num_of_threads=$THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": $DISK_SIZE, "disk_name": $DISK_NAME,"sync_atomicity": false,"enable_gc":true}}]
    ' Occlum.json)"
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "${BOMFILE}" --root image --include-dir /opt/occlum/etc/template >&2
    occlum build >&2

    cd "${SCRIPT_DIR}"
}

run_cleaning() {
    local log_file="${OUTPUT_DIR}/cleaning_$(date +%Y%m%d_%H%M%S).log"
    echo -e "${GREEN}Running cleaning benchmark inside Occlum...${NC}" >&2
    echo -e "${GREEN}Disk: ${DISK_PATH}, Total: ${TOTAL_GB} GiB, Batch: ${BATCH_GB} GiB, Used rate: ${USED_RATE}, Interval: ${INTERVAL_SEC}s, Loops: ${LOOP_TIMES}${NC}" >&2

    cd "${SCRIPT_DIR}/occlum_instance"
    occlum run /bin/cleaning "${DISK_PATH}" "${TOTAL_GB}" "${BATCH_GB}" "${USED_RATE}" "${INTERVAL_SEC}" "${LOOP_TIMES}" 2>&1 | tee "${log_file}" >&2
    cd "${SCRIPT_DIR}"

    echo -e "${GREEN}Benchmark complete. Log saved to ${log_file}${NC}" >&2
}

main() {
    mkdir -p "${OUTPUT_DIR}"
    compile_cleaning
    init_occlum_instance
    run_cleaning
}

main "$@"

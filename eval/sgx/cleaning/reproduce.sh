#!/bin/bash
set -euo pipefail

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOMFILE="${SCRIPT_DIR}/cleaning.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/results"

# Tunables (override via env)
DISK_PATH=${DISK_PATH:-/dev/sworndisk}
TOTAL_GB=${TOTAL_GB:-100}
BATCH_GB=${BATCH_GB:-10}
USED_RATE=${USED_RATE:-0.8}
LOOP_TIMES=${LOOP_TIMES:-10}
DISK_SIZE=${DISK_SIZE:-120GB}

# Test configurations: (enable_gc, interval_sec, config_name)
declare -a CONFIGS=(
    "false,0,gc_off_interval_0"
    "true,30,gc_on_interval_30"
    "true,60,gc_on_interval_60"
    "true,90,gc_on_interval_90"
)

compile_cleaning() {
    echo -e "${YELLOW}Compiling cleaning benchmark...${NC}" >&2
    cd "${SCRIPT_DIR}"
    g++ cleaning.cpp -std=c++17 -O2 -Wall -Wextra -o cleaning
}

init_occlum_instance() {
    local enable_gc=$1
    echo -e "${YELLOW}Initializing Occlum instance (enable_gc=${enable_gc})...${NC}" >&2
    cd "${SCRIPT_DIR}"
    rm -rf occlum_instance && occlum new occlum_instance >&2
    cd occlum_instance

    TCS_NUM=$(($(nproc) * 2))
    new_json="$(jq --argjson THREAD_NUM "${TCS_NUM}" \
                   --arg DISK_NAME "sworndisk" \
                   --arg DISK_SIZE "${DISK_SIZE}" \
                   --argjson ENABLE_GC "${enable_gc}" '
        .resource_limits.user_space_size="2000MB" |
        .resource_limits.user_space_max_size="2000MB" |
        .resource_limits.kernel_space_heap_size="5000MB" |
        .resource_limits.kernel_space_heap_max_size="5000MB" |
        .resource_limits.max_num_of_threads=$THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": $DISK_SIZE, "disk_name": $DISK_NAME, "sync_atomicity": false, "enable_gc": $ENABLE_GC}}]
    ' Occlum.json)"
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "${BOMFILE}" --root image --include-dir /opt/occlum/etc/template >&2
    occlum build >&2

    cd "${SCRIPT_DIR}"
}

extract_throughput() {
    local log_file=$1
    local output_file=$2

    # Extract round throughput from log and save to CSV
    grep -oP 'round\[\d+\] throughput: \K[0-9.]+' "${log_file}" > "${output_file}"
    echo -e "${GREEN}Throughput extracted to ${output_file}${NC}" >&2
}

run_cleaning() {
    local interval_sec=$1
    local config_name=$2
    local enable_gc=$3
    local log_file="${OUTPUT_DIR}/cleaning_${config_name}_$(date +%Y%m%d_%H%M%S).log"

    # Determine result filename based on gc status
    local result_file
    if [ "${enable_gc}" = "false" ]; then
        result_file="${OUTPUT_DIR}/throughput_gc_off.csv"
    else
        result_file="${OUTPUT_DIR}/throughput_interval_${interval_sec}.csv"
    fi

    echo -e "${GREEN}Running cleaning benchmark (config: ${config_name}, interval: ${interval_sec}s)...${NC}" >&2
    echo -e "${GREEN}Disk: ${DISK_PATH}, Total: ${TOTAL_GB} GiB, Batch: ${BATCH_GB} GiB, Used rate: ${USED_RATE}, Loops: ${LOOP_TIMES}${NC}" >&2

    cd "${SCRIPT_DIR}/occlum_instance"
    occlum run /bin/cleaning "${DISK_PATH}" "${TOTAL_GB}" "${BATCH_GB}" "${USED_RATE}" "${interval_sec}" "${LOOP_TIMES}" 2>&1 | tee "${log_file}" >&2
    cd "${SCRIPT_DIR}"

    echo -e "${GREEN}Benchmark complete. Log saved to ${log_file}${NC}" >&2

    # Extract throughput from log
    extract_throughput "${log_file}" "${result_file}"
}

run_single_config() {
    local config=$1
    IFS=',' read -r enable_gc interval_sec config_name <<< "${config}"

    echo -e "${BLUE}========================================${NC}" >&2
    echo -e "${BLUE}Testing configuration: ${config_name}${NC}" >&2
    echo -e "${BLUE}  enable_gc: ${enable_gc}${NC}" >&2
    echo -e "${BLUE}  interval:  ${interval_sec}s${NC}" >&2
    echo -e "${BLUE}========================================${NC}" >&2

    init_occlum_instance "${enable_gc}"
    run_cleaning "${interval_sec}" "${config_name}" "${enable_gc}"

    echo -e "${GREEN}Configuration ${config_name} completed.${NC}" >&2
    echo "" >&2
}

main() {
    mkdir -p "${OUTPUT_DIR}"
    compile_cleaning

    local total_configs=${#CONFIGS[@]}
    local current=0

    for config in "${CONFIGS[@]}"; do
        ((++current))
        echo -e "${BLUE}>>> Running test ${current}/${total_configs} <<<${NC}" >&2
        run_single_config "${config}"
    done

    echo -e "${GREEN}========================================${NC}" >&2
    echo -e "${GREEN}All ${total_configs} configurations completed!${NC}" >&2
    echo -e "${GREEN}Results saved in: ${OUTPUT_DIR}${NC}" >&2
    echo -e "${GREEN}========================================${NC}" >&2
}

main "$@"

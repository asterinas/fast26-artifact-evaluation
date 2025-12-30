#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BOMFILE=${SCRIPT_DIR}/trace.yaml
OUTPUT_DIR="${SCRIPT_DIR}/results"

# Trace datasets (only the 0-variants)
TRACES=("hm_0" "mds_0" "prn_0" "wdev_0" "web_0")

# Disk types to test
DISK_TYPES=("PfsDisk" "sworndisk" "cryptdisk")

# Disk paths for each disk type (inside Occlum)
declare -A DISK_PATHS
DISK_PATHS["PfsDisk"]="/root/diskfile"
DISK_PATHS["sworndisk"]="/ext2/sworndisk"
DISK_PATHS["cryptdisk"]="/ext2/cryptdisk"

function compile_trace() {
    echo -e "${YELLOW}Compiling trace program...${NC}" >&2
    cd "${SCRIPT_DIR}"
    g++ trace.cpp -std=c++11 -o trace
}

function init_occlum_instance() {
    local disk_type=$1
    echo -e "${YELLOW}Initializing Occlum instance for ${disk_type}...${NC}" >&2

    cd "${SCRIPT_DIR}"
    rm -rf occlum_instance && occlum new occlum_instance >&2
    cd occlum_instance

    TCS_NUM=$(($(nproc) * 2))

    if [ "$disk_type" == "PfsDisk" ]; then
        # PfsDisk: no ext2 mount needed
        new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} '
            .resource_limits.user_space_size="2000MB" |
            .resource_limits.user_space_max_size = "2000MB" |
            .resource_limits.kernel_space_heap_size = "2000MB" |
            .resource_limits.kernel_space_heap_max_size="2000MB" |
            .resource_limits.max_num_of_threads = $THREAD_NUM' Occlum.json)"
    else
        # SwornDisk or CryptDisk: mount ext2
        new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} --arg DISK_NAME "$disk_type" '
            .resource_limits.user_space_size="2000MB" |
            .resource_limits.user_space_max_size = "2000MB" |
            .resource_limits.kernel_space_heap_size = "2000MB" |
            .resource_limits.kernel_space_heap_max_size="2000MB" |
            .resource_limits.max_num_of_threads = $THREAD_NUM |
            .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": "80GB", "disk_name": $DISK_NAME}}]' Occlum.json)"
    fi

    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "$BOMFILE" --root image --include-dir /opt/occlum/etc/template >&2
    occlum build >&2

    cd "${SCRIPT_DIR}"
}

function run_trace_test() {
    local disk_type=$1
    local trace_file=$2
    local output_file="${OUTPUT_DIR}/${trace_file}_${disk_type}_output.txt"
    local disk_path=${DISK_PATHS[$disk_type]}

    echo -e "${GREEN}Running trace [${trace_file}] on ${disk_type}...${NC}" >&2

    cd "${SCRIPT_DIR}/occlum_instance"
    occlum run /bin/trace "${disk_path}" "/msr-test/${trace_file}.csv" 2>&1 | tee "${output_file}" >&2
    cd "${SCRIPT_DIR}"
}

function parse_results() {
    local trace_file=$1
    local disk_type=$2
    local output_file="${OUTPUT_DIR}/${trace_file}_${disk_type}_output.txt"

    local bandwidth=$(grep "^Bandwidth:" "${output_file}" 2>/dev/null | awk '{print $2}' | sed 's/MiB\/s//' )

    echo "{\"trace\":\"${trace_file}\",\"disk_type\":\"${disk_type}\",\"bandwidth_mb_s\":${bandwidth:-0}}"
}

# Main
mkdir -p "${OUTPUT_DIR}"

compile_trace

RESULT_JSON="${OUTPUT_DIR}/trace_reproduce_result.json"
all_results=()

# Iterate disks first, then traces. Reuse occlum instance for PfsDisk,
# recreate per trace for sworndisk/cryptdisk (log-structured/out-of-place).
for disk_type in "${DISK_TYPES[@]}"; do
    echo -e "${YELLOW}===== Disk: ${disk_type} =====${NC}" >&2
    if [ "$disk_type" == "sworndisk" ] || [ "$disk_type" == "cryptdisk" ]; then
        for trace_file in "${TRACES[@]}"; do
            echo -e "\n${YELLOW}========== Testing ${trace_file} on ${disk_type} ==========${NC}\n" >&2
            init_occlum_instance "$disk_type"
            run_trace_test "$disk_type" "$trace_file"
            all_results+=("$(parse_results "$trace_file" "$disk_type")")
        done
    else
        init_occlum_instance "$disk_type"
        for trace_file in "${TRACES[@]}"; do
            echo -e "\n${YELLOW}========== Testing ${trace_file} on ${disk_type} ==========${NC}\n" >&2
            run_trace_test "$disk_type" "$trace_file"
            all_results+=("$(parse_results "$trace_file" "$disk_type")")
        done
    fi
done

# Generate JSON output
echo "[" > "${RESULT_JSON}"
printf '%s\n' "${all_results[@]}" | sed 's/$/,/' | sed '$ s/,$//' >> "${RESULT_JSON}"
echo "]" >> "${RESULT_JSON}"

echo -e "\n${GREEN}========== Benchmark Complete ==========${NC}" >&2
echo -e "${GREEN}Results saved to: ${RESULT_JSON}${NC}" >&2
cat "${RESULT_JSON}"

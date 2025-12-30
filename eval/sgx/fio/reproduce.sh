#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BOMFILE=${SCRIPT_DIR}/fio.yaml
FIO_CONFIG="reproduce.fio"
OUTPUT_DIR="${SCRIPT_DIR}/results"
RESULT_JSON="${OUTPUT_DIR}/reproduce_result.json"

# Test sections
WRITE_TESTS=("seq-write-256k" "rand-write-4k" "rand-write-32k" "rand-write-256k")
READ_TESTS=("seq-read-256k" "rand-read-4k" "rand-read-32k" "rand-read-256k")

# Map fio sections to result keys and types
declare -A TEST_KEYS=(
    ["seq-write-256k"]="seq_write_256k"
    ["rand-write-4k"]="rand_write_4k"
    ["rand-write-32k"]="rand_write_32k"
    ["rand-write-256k"]="rand_write_256k"
    ["seq-read-256k"]="seq_read_256k"
    ["rand-read-4k"]="rand_read_4k"
    ["rand-read-32k"]="rand_read_32k"
    ["rand-read-256k"]="rand_read_256k"
)

declare -A TEST_TYPES=(
    ["seq-write-256k"]="write"
    ["rand-write-4k"]="write"
    ["rand-write-32k"]="write"
    ["rand-write-256k"]="write"
    ["seq-read-256k"]="read"
    ["rand-read-4k"]="read"
    ["rand-read-32k"]="read"
    ["rand-read-256k"]="read"
)

# Disk types to test
DISK_TYPES=("cryptdisk")

# Write paths for each disk type (directly use block device)
declare -A WRITE_PATHS
WRITE_PATHS["PfsDisk"]="/root/fio-test"
WRITE_PATHS["sworndisk"]="/dev/sworndisk"
WRITE_PATHS["cryptdisk"]="/dev/cryptdisk"

# Read path (use ext2 filesystem)
READ_PATH="/ext2/fio-test"

function check_fio() {
    if [ ! -e ${SCRIPT_DIR}/fio_src/fio ]; then
        echo "Error: fio not found. Building fio first..."
        ./download_and_build_fio.sh
    fi
}

function init_occlum_instance() {
    local disk_type=$1
    echo -e "${YELLOW}Initializing Occlum instance for ${disk_type}...${NC}"
    
    rm -rf occlum_instance && occlum new occlum_instance
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
            .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": "60GB", "disk_name": $DISK_NAME}}]' Occlum.json)"
    fi
    echo "${new_json}" > Occlum.json
    
    rm -rf image
    copy_bom -f $BOMFILE --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

function run_fio_section() {
    local disk_type=$1
    local section=$2
    local test_path=$3
    local output_file=$4
    local config=${5:-$FIO_CONFIG}

    echo -e "${GREEN}Running fio [${section}] on ${disk_type} (path: ${test_path})...${NC}"

    cd occlum_instance
    occlum run /bin/fio --filename="${test_path}" "/configs/${config}" --section="${section}" 2>&1 | tee "${output_file}"
    cd ..
}

function run_fio_all_sections() {
    local disk_type=$1
    local test_path=$2
    local config=$3
    local output_file=$4

    echo -e "${GREEN}Running all fio sections on ${disk_type} (path: ${test_path})...${NC}"

    cd occlum_instance
    occlum run /bin/fio --filename="${test_path}" "/configs/${config}" 2>&1 | tee "${output_file}"
    cd ..
}

function parse_single_result() {
    local output_file=$1
    local test_type=$2
    local metric_field

    if [ "$test_type" == "write" ]; then
        metric_field=$(grep "WRITE:" "${output_file}" | awk '{print $2}' || true)
    else
        metric_field=$(grep "READ:" "${output_file}" | awk '{print $2}' || true)
    fi

    # Extract number from bw=XXXMiB/s format
    echo $(echo ${metric_field} | sed 's/bw=//;s/MiB.*//')
}

function parse_read_results() {
    local output_file=$1
    local section=$2

    # Extract the specific section's read result from combined output
    # Format: "seq-read-256k: (groupid=1, jobs=1): ..." followed by "  read: IOPS=xxx, BW=769MiB/s ..."
    # Use awk to find section header then get BW from next "read:" line
    local result=$(awk "/${section}:.*groupid/{found=1; next} found && /^[[:space:]]+read:/{print \$3; found=0}" "${output_file}" | head -1)
    echo $(echo ${result} | sed 's/BW=//;s/MiB.*//')
}

function main() {
    mkdir -p "${OUTPUT_DIR}"
    check_fio
    
    local results=()
    
    for disk_type in "${DISK_TYPES[@]}"; do
        echo -e "\n${YELLOW}========== Testing ${disk_type} ==========${NC}\n"
        local write_path=${WRITE_PATHS[$disk_type]}
        declare -A metrics=()

        # Write tests: each on a fresh Occlum instance to avoid log-structured residue
        # Write tests use block device directly (/dev/xxxdisk)
        for section in "${WRITE_TESTS[@]}"; do
            init_occlum_instance "$disk_type"
            local output_file="${OUTPUT_DIR}/${disk_type}_${section}_output.txt"
            run_fio_section "$disk_type" "$section" "$write_path" "$output_file"
            metrics[${TEST_KEYS[$section]}]=$(parse_single_result "$output_file" "${TEST_TYPES[$section]}")
        done

        # Read tests: one Occlum instance, run all read tests in sequence (reuse same file)
        # Read tests use ext2 filesystem (/ext2/fio-test)
        # reproduce-read.fio contains: layout -> seq-read -> rand-read-4k -> rand-read-32k -> rand-read-256k
        init_occlum_instance "$disk_type"
        local read_output_file="${OUTPUT_DIR}/${disk_type}_read_output.txt"
        run_fio_all_sections "$disk_type" "$READ_PATH" "reproduce-read.fio" "$read_output_file"

        # Parse results for each read test from combined output
        for section in "${READ_TESTS[@]}"; do
            metrics[${TEST_KEYS[$section]}]=$(parse_read_results "$read_output_file" "$section")
        done

        results+=("{\"disk_type\":\"${disk_type}\",\"seq_write_256k\":${metrics[seq_write_256k]:-0},\"rand_write_4k\":${metrics[rand_write_4k]:-0},\"rand_write_32k\":${metrics[rand_write_32k]:-0},\"rand_write_256k\":${metrics[rand_write_256k]:-0},\"seq_read_256k\":${metrics[seq_read_256k]:-0},\"rand_read_4k\":${metrics[rand_read_4k]:-0},\"rand_read_32k\":${metrics[rand_read_32k]:-0},\"rand_read_256k\":${metrics[rand_read_256k]:-0}}")
    done
    
    # Generate final JSON
    echo "[" > "${RESULT_JSON}"
    for i in "${!results[@]}"; do
        if [ $i -gt 0 ]; then echo "," >> "${RESULT_JSON}"; fi
        echo "  ${results[$i]}" >> "${RESULT_JSON}"
    done
    echo "]" >> "${RESULT_JSON}"
    
    echo -e "\n${GREEN}Benchmark complete! Results saved to ${RESULT_JSON}${NC}"
    cat "${RESULT_JSON}"
}

main "$@"

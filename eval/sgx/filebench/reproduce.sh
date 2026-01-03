#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BOMFILE=${SCRIPT_DIR}/filebench.yaml
OUTPUT_DIR="${SCRIPT_DIR}/results"

# Workloads to test
WORKLOADS=("fileserver" "oltp" "varmail" "videoserver")

# Disk types to test (all use ext2 mount now)
DISK_TYPES=("pfsdisk" "sworndisk" "cryptdisk")

# Test directory path (all use ext2)
TEST_DIR="/ext2/fbtest"

# Disk size per workload
declare -A DISK_SIZES
DISK_SIZES["fileserver"]="10GB"
DISK_SIZES["oltp"]="10GB"
DISK_SIZES["varmail"]="10GB"
DISK_SIZES["videoserver"]="40GB"

function usage() {
    echo "Usage: $0 [workload]"
    echo "  workload: fileserver | oltp | varmail | videoserver | all (default: all)"
    exit 1
}

function check_filebench() {
    if [ ! -e ${SCRIPT_DIR}/filebench/filebench ]; then
        echo "Error: filebench not found. Building filebench first..."
        ./dl_and_build_filebench.sh
    fi
}

function generate_workload_file() {
    local workload=$1
    local disk_type=$2
    local template_file="${SCRIPT_DIR}/workloads/${workload}-template.f"
    local output_file="${SCRIPT_DIR}/workloads/${workload}-${disk_type}.f"

    if [ ! -e "${template_file}" ]; then
        echo -e "${RED}Template not found: ${template_file}${NC}"
        return 1
    fi

    # Replace placeholder with actual directory
    sed 's|\$BENCHMARK_DIR\$|'"${TEST_DIR}"'|g' "${template_file}" > "${output_file}"

    echo "${workload}-${disk_type}.f"
}

function init_occlum_instance() {
    local disk_type=$1
    local disk_size=$2
    echo -e "${YELLOW}Initializing Occlum instance for ${disk_type} (disk_size=${disk_size})...${NC}" >&2

    rm -rf occlum_instance && occlum new occlum_instance
    cd occlum_instance

    TCS_NUM=$(($(nproc) * 2))

    # All disk types use ext2 mount
    new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} --arg DISK_NAME "$disk_type" --arg DISK_SIZE "$disk_size" '
        .resource_limits.user_space_size="10000MB" |
        .resource_limits.user_space_max_size = "10000MB" |
        .resource_limits.kernel_space_heap_size = "5000MB" |
        .resource_limits.kernel_space_heap_max_size="5000MB" |
        .resource_limits.max_num_of_threads = $THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": $DISK_SIZE, "disk_name": $DISK_NAME}}]' Occlum.json)"
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f $BOMFILE --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

function run_filebench_test() {
    local disk_type=$1
    local workload=$2
    local workload_file=$3
    local output_file="${OUTPUT_DIR}/${workload}_${disk_type}_output.txt"

    echo -e "${GREEN}Running filebench [${workload}] on ${disk_type}...${NC}" >&2

    cd occlum_instance
    # Disable exit on error for this command to ensure we continue with other workloads
    set +e
    occlum run /bin/filebench -f "/workloads/${workload_file}" 2>&1 | tee "${output_file}" >&2
    local exit_code=$?
    set -e

    if [ $exit_code -ne 0 ]; then
        echo -e "${YELLOW}Warning: filebench exited with code ${exit_code}${NC}" >&2
    fi
    cd ..
}

function run_single_workload() {
    local workload=$1
    local disk_size=${DISK_SIZES[$workload]}

    for disk_type in "${DISK_TYPES[@]}"; do
        echo -e "\n${YELLOW}========== Testing ${workload} on ${disk_type} (${disk_size}) ==========${NC}\n" >&2

        # Generate workload file with correct path
        local workload_file=$(generate_workload_file "$workload" "$disk_type" 2>/dev/null)
        if [ $? -ne 0 ]; then
            continue
        fi

        init_occlum_instance "$disk_type" "$disk_size" >&2
        run_filebench_test "$disk_type" "$workload" "$workload_file"
    done
}

function main() {
    local selected_workload="${1:-all}"

    mkdir -p "${OUTPUT_DIR}"
    check_filebench

    if [ "$selected_workload" == "all" ]; then
        for workload in "${WORKLOADS[@]}"; do
            run_single_workload "$workload"
        done
    else
        # Check if workload is valid
        if [[ ! " ${WORKLOADS[@]} " =~ " ${selected_workload} " ]]; then
            echo -e "${RED}Invalid workload: ${selected_workload}${NC}"
            usage
        fi
        run_single_workload "$selected_workload"
    fi

    # Parse results using the dedicated script
    local FINAL_RESULT_JSON="${OUTPUT_DIR}/filebench_results.json"
    echo -e "\n${YELLOW}Parsing benchmark results...${NC}"
    "${SCRIPT_DIR}/parse_filebench_results.sh" "${OUTPUT_DIR}" "${FINAL_RESULT_JSON}"

    echo -e "\n${GREEN}Benchmark complete! Results saved to ${FINAL_RESULT_JSON}${NC}"
}

main "$@"

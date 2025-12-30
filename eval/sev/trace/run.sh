#!/bin/bash
set -e

# ============================================================
# DEVICE PATH CONFIGURATION (modify these paths as needed)
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"

# ============================================================
# Script Configuration
# ============================================================
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"
TRACE_DIR="${SCRIPT_DIR}/msr-test"

# Reset script for sworndisk (run after each trace test)
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"

# Trace datasets (only the 0-variants)
TRACES=("hm_0" "mds_0" "prn_0" "wdev_0" "web_0")

# Disk types to test
DISK_TYPES=("sworndisk" "cryptdisk")

# Block device paths for direct testing (no filesystem)
declare -A DEVICE_PATHS
DEVICE_PATHS["sworndisk"]="$SWORNDISK_DEVICE"
DEVICE_PATHS["cryptdisk"]="$CRYPTDISK_DEVICE"

function check_compiler() {
    if ! command -v g++ &> /dev/null; then
        echo -e "${RED}Error: g++ not found. Please install g++ first.${NC}"
        echo "  sudo apt install -y build-essential"
        exit 1
    fi
    echo -e "${GREEN}Found g++: $(g++ --version | head -1)${NC}"
}

function check_trace_data() {
    if [ ! -d "$TRACE_DIR" ]; then
        echo -e "${YELLOW}Trace data not found at $TRACE_DIR${NC}"
        echo -e "${RED}Please download trace data or copy msr-test directory to ${SCRIPT_DIR}${NC}"
        exit 1
    fi

    # Verify trace files exist
    for trace in "${TRACES[@]}"; do
        if [ ! -f "${TRACE_DIR}/${trace}.csv" ]; then
            echo -e "${RED}Error: Trace file ${trace}.csv not found in ${TRACE_DIR}${NC}"
            exit 1
        fi
    done

    echo -e "${GREEN}All trace files found${NC}"
}

function compile_trace() {
    echo -e "${YELLOW}Compiling trace program...${NC}"
    cd "${SCRIPT_DIR}"
    g++ trace.cpp -std=c++11 -o trace
    echo -e "${GREEN}Compilation successful${NC}"
}

function check_device() {
    local device=$1

    if [ ! -e "$device" ]; then
        echo -e "${RED}Error: Device $device not found${NC}"
        echo -e "${YELLOW}Please ensure the device mapper is set up correctly${NC}"
        return 1
    fi

    if [ ! -b "$device" ]; then
        echo -e "${RED}Error: $device is not a block device${NC}"
        return 1
    fi

    if [ ! -r "$device" ] || [ ! -w "$device" ]; then
        echo -e "${RED}Error: Device $device is not readable/writable${NC}"
        echo -e "${YELLOW}You may need root permissions to access block devices${NC}"
        return 1
    fi

    echo -e "${GREEN}Device $device is accessible${NC}"
    return 0
}

function sync_device() {
    local device=$1
    echo -e "${YELLOW}Syncing device ${device}...${NC}"
    sync
    # Wait for pending I/O to complete
    sleep 1
    echo -e "${GREEN}Sync complete${NC}"
}

function reset_sworndisk() {
    if [ ! -f "$RESET_SWORN_SCRIPT" ]; then
        echo -e "${RED}Error: Reset script not found at $RESET_SWORN_SCRIPT${NC}"
        return 1
    fi

    echo -e "${YELLOW}Resetting sworndisk...${NC}"
    bash "$RESET_SWORN_SCRIPT"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Sworndisk reset complete${NC}"
        return 0
    else
        echo -e "${RED}Error: Failed to reset sworndisk${NC}"
        return 1
    fi
}

function run_trace_test() {
    local disk_type=$1
    local trace_file=$2
    local device=${DEVICE_PATHS[$disk_type]}
    local output_file="${OUTPUT_DIR}/${trace_file}_${disk_type}_output.txt"

    echo -e "${GREEN}Running trace [${trace_file}] on ${disk_type}...${NC}"
    echo -e "${GREEN}Device path: ${device}${NC}"
    echo -e "${GREEN}Trace file: ${TRACE_DIR}/${trace_file}.csv${NC}"

    # Run the trace program
    "${SCRIPT_DIR}/trace" "${device}" "${TRACE_DIR}/${trace_file}.csv" 2>&1 | tee "${output_file}"
}

function parse_results() {
    local trace_file=$1
    local disk_type=$2
    local output_file="${OUTPUT_DIR}/${trace_file}_${disk_type}_output.txt"

    local bandwidth=$(grep "^Avg Bandwidth:" "${output_file}" 2>/dev/null | awk '{print $3}' | sed 's/MiB\/s//')

    echo "{\"trace\":\"${trace_file}\",\"disk_type\":\"${disk_type}\",\"bandwidth_mb_s\":${bandwidth:-0}}"
}

function main() {
    mkdir -p "${OUTPUT_DIR}"

    check_compiler
    check_trace_data
    compile_trace

    echo -e "\n${YELLOW}========== Starting Trace Benchmark ==========${NC}\n"
    echo -e "${YELLOW}Testing block devices directly (no filesystem)${NC}\n"

    RESULT_JSON="${OUTPUT_DIR}/result.json"
    all_results=()

    # Iterate disks, then traces
    # For sworndisk and cryptdisk, sync device before and after each trace run
    for disk_type in "${DISK_TYPES[@]}"; do
        echo -e "\n${YELLOW}===== Testing ${disk_type} =====${NC}\n"

        local device=${DEVICE_PATHS[$disk_type]}

        # Check if device is accessible
        if ! check_device "$device"; then
            echo -e "${RED}Skipping ${disk_type} - device not accessible${NC}"
            continue
        fi

        for trace_file in "${TRACES[@]}"; do
            echo -e "\n${YELLOW}========== Testing ${trace_file} on ${disk_type} ==========${NC}\n"

            # Sync before each test
            sync_device "$device"

            # Run trace test
            run_trace_test "$disk_type" "$trace_file"

            # Parse and store results
            all_results+=("$(parse_results "$trace_file" "$disk_type")")

            # Sync after test
            sync_device "$device"

            # Reset sworndisk after each trace test
            if [ "$disk_type" == "sworndisk" ]; then
                reset_sworndisk
            fi
        done
    done

    # Generate JSON output
    echo "[" > "${RESULT_JSON}"
    printf '%s\n' "${all_results[@]}" | sed 's/$/,/' | sed '$ s/,$//' >> "${RESULT_JSON}"
    echo "]" >> "${RESULT_JSON}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Benchmark complete!${NC}"
    echo -e "${GREEN}Results saved to ${RESULT_JSON}${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    cat "${RESULT_JSON}"

    echo -e "\n${YELLOW}To plot results, run:${NC}"
    echo -e "  python3 plot_result.py"
}

main "$@"

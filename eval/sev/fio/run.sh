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
FIO_CONFIG="reproduce.fio"
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"
RESULT_JSON="${OUTPUT_DIR}/result.json"

# Reset script for sworndisk (run after each write test)
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"

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
DISK_TYPES=("sworndisk" "cryptdisk")

# Block device paths for direct testing (no filesystem)
declare -A DEVICE_PATHS
DEVICE_PATHS["sworndisk"]="$SWORNDISK_DEVICE"
DEVICE_PATHS["cryptdisk"]="$CRYPTDISK_DEVICE"

function check_fio() {
    if ! command -v fio &> /dev/null; then
        echo -e "${RED}Error: fio not found. Please install fio first.${NC}"
        echo "  sudo apt install -y fio"
        exit 1
    fi
    echo -e "${GREEN}Found fio: $(fio --version)${NC}"
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

function run_fio_section() {
    local disk_type=$1
    local section=$2
    local device=$3
    local output_file=$4
    local config=${5:-$FIO_CONFIG}

    echo -e "${GREEN}Running fio [${section}] on ${disk_type} (device: ${device})...${NC}"
    fio --filename="${device}" "${SCRIPT_DIR}/configs/${config}" --section="${section}" 2>&1 | tee "${output_file}"
}

function run_fio_all_sections() {
    local disk_type=$1
    local device=$2
    local config=$3
    local output_file=$4

    echo -e "${GREEN}Running all fio sections on ${disk_type} (device: ${device})...${NC}"
    fio --filename="${device}" "${SCRIPT_DIR}/configs/${config}" 2>&1 | tee "${output_file}"
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
    local result=$(echo ${metric_field} | sed 's/bw=//;s/MiB.*//')

    # If result is empty, return 0
    if [ -z "$result" ]; then
        echo "0"
    else
        echo "$result"
    fi
}

function parse_read_results() {
    local output_file=$1
    local section=$2

    # Extract the specific section's read result from combined output
    local result=$(awk "/${section}:.*groupid/{found=1; next} found && /^[[:space:]]+read:/{print \$3; found=0}" "${output_file}" | head -1)
    local bw=$(echo ${result} | sed 's/BW=//;s/MiB.*//')

    # If bw is empty, return 0
    if [ -z "$bw" ]; then
        echo "0"
    else
        echo "$bw"
    fi
}

function main() {
    mkdir -p "${OUTPUT_DIR}"
    check_fio

    echo -e "\n${YELLOW}========== Starting FIO Benchmark ==========${NC}\n"
    echo -e "${YELLOW}Testing block devices directly (no filesystem)${NC}\n"

    local results=()

    for disk_type in "${DISK_TYPES[@]}"; do
        echo -e "\n${YELLOW}========== Testing ${disk_type} ==========${NC}\n"
        local device=${DEVICE_PATHS[$disk_type]}

        # Check if device is accessible
        if ! check_device "$device"; then
            echo -e "${RED}Skipping ${disk_type} - device not accessible${NC}"
            continue
        fi

        declare -A metrics=()

        # Write tests: sync device before each test, reset sworndisk after each write test
        for section in "${WRITE_TESTS[@]}"; do
            sync_device "$device"
            local output_file="${OUTPUT_DIR}/${disk_type}_${section}_output.txt"
            run_fio_section "$disk_type" "$section" "$device" "$output_file"
            metrics[${TEST_KEYS[$section]}]=$(parse_single_result "$output_file" "${TEST_TYPES[$section]}")
            echo -e "${GREEN}${section}: ${metrics[${TEST_KEYS[$section]}]} MiB/s${NC}"

            # Reset sworndisk after each write test
            if [ "$disk_type" == "sworndisk" ]; then
                reset_sworndisk
            fi
        done

        # Read tests: prepare data once, then run all read tests
        sync_device "$device"
        local read_output_file="${OUTPUT_DIR}/${disk_type}_read_output.txt"
        run_fio_all_sections "$disk_type" "$device" "reproduce-read.fio" "$read_output_file"

        # Parse results for each read test from combined output
        for section in "${READ_TESTS[@]}"; do
            metrics[${TEST_KEYS[$section]}]=$(parse_read_results "$read_output_file" "$section")
            echo -e "${GREEN}${section}: ${metrics[${TEST_KEYS[$section]}]} MiB/s${NC}"
        done

        # Sync after all tests
        sync_device "$device"

        results+=("{\"disk_type\":\"${disk_type}\",\"seq_write_256k\":${metrics[seq_write_256k]:-0},\"rand_write_4k\":${metrics[rand_write_4k]:-0},\"rand_write_32k\":${metrics[rand_write_32k]:-0},\"rand_write_256k\":${metrics[rand_write_256k]:-0},\"seq_read_256k\":${metrics[seq_read_256k]:-0},\"rand_read_4k\":${metrics[rand_read_4k]:-0},\"rand_read_32k\":${metrics[rand_read_32k]:-0},\"rand_read_256k\":${metrics[rand_read_256k]:-0}}")
    done

    # Generate final JSON
    echo "[" > "${RESULT_JSON}"
    for i in "${!results[@]}"; do
        if [ $i -gt 0 ]; then echo "," >> "${RESULT_JSON}"; fi
        echo "  ${results[$i]}" >> "${RESULT_JSON}"
    done
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


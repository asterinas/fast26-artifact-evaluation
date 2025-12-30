#!/bin/bash

# Script to run RocksDB benchmarks using cpp-ycsb
# Tests workloads a, b, e on SwornDisk and CryptDisk
# Note: workloadf is not supported by cpp-ycsb (only a-e)

set -e

# ============================================================
# DEVICE & FILESYSTEM PATHS
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"

SWORNDISK_MOUNT="/mnt/sworndisk"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

# Data roots on each mounted filesystem
SWORNDISK_DATA_ROOT="${SWORNDISK_MOUNT}/ycsb"
CRYPTDISK_DATA_ROOT="${CRYPTDISK_MOUNT}/ycsb"

# Reset and mount helpers
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
MOUNT_SCRIPT="${SCRIPT_DIR}/../mount_filesystems.sh"
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'

YCSB_BIN="${SCRIPT_DIR}/cpp-ycsb/bin/ycsb"
WORKLOAD_DIR="${SCRIPT_DIR}/workloads"
RESULT_FILE="${OUTPUT_DIR}/rocksdb_results.json"

# Check if cpp-ycsb binary exists
if [ ! -f "${YCSB_BIN}" ]; then
    echo -e "${RED}Error: cpp-ycsb binary not found at ${YCSB_BIN}${NC}"
    echo -e "${YELLOW}Please run: cd cpp-ycsb && ./build.sh${NC}"
    exit 1
fi

# Check if workload directory exists
if [ ! -d "${WORKLOAD_DIR}" ]; then
    echo -e "${RED}Error: workload directory not found at ${WORKLOAD_DIR}${NC}"
    exit 1
fi

# Workloads to test (cpp-ycsb now supports a-f)
WORKLOADS=("workloada" "workloadb" "workloade" "workloadf")
RECORD_COUNT=100000
OPERATION_COUNT=100000

# Test database directories (RocksDB uses directories)
SWORNDISK_DIR="${SWORNDISK_DATA_ROOT}/rocksdb"
CRYPTDISK_DIR="${CRYPTDISK_DATA_ROOT}/rocksdb"

check_mount_point() {
    local mountpoint=$1

    if ! mountpoint -q "$mountpoint"; then
        return 1
    fi

    if [ ! -w "$mountpoint" ]; then
        return 1
    fi

    return 0
}

ensure_filesystems() {
    local ready=true

    if ! check_mount_point "${SWORNDISK_MOUNT}"; then
        ready=false
    fi
    if ! check_mount_point "${CRYPTDISK_MOUNT}"; then
        ready=false
    fi

    if [ "$ready" = false ]; then
        echo -e "${YELLOW}Mounting filesystems...${NC}"
        if [ ! -x "${MOUNT_SCRIPT}" ]; then
            echo -e "${RED}Mount script not found at ${MOUNT_SCRIPT}${NC}"
            exit 1
        fi
        bash "${MOUNT_SCRIPT}"
    fi

    if ! check_mount_point "${SWORNDISK_MOUNT}" || ! check_mount_point "${CRYPTDISK_MOUNT}"; then
        echo -e "${RED}Error: filesystems not mounted or writable${NC}"
        exit 1
    fi
}

umount_if_mounted() {
    local mountpoint=$1
    if mountpoint -q "$mountpoint"; then
        echo -e "${YELLOW}Unmounting ${mountpoint}...${NC}"
        umount "$mountpoint" || echo -e "${RED}Failed to unmount ${mountpoint}${NC}"
    fi
}

reset_sworndisk() {
    if [ -x "${RESET_SWORN_SCRIPT}" ]; then
        echo -e "${YELLOW}Resetting sworndisk...${NC}"
        bash "${RESET_SWORN_SCRIPT}" || echo -e "${RED}Failed to reset sworndisk${NC}"
    else
        echo -e "${YELLOW}Reset script not found at ${RESET_SWORN_SCRIPT}${NC}"
    fi
}

CLEANUP_ENABLED=false

cleanup() {
    if [ "${CLEANUP_ENABLED}" != true ]; then
        return
    fi
    umount_if_mounted "${SWORNDISK_MOUNT}"
    umount_if_mounted "${CRYPTDISK_MOUNT}"
    reset_sworndisk
}

trap cleanup EXIT

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}RocksDB Benchmark - cpp-ycsb${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Workloads to test: ${WORKLOADS[@]}"
echo "Results will be saved to: ${RESULT_FILE}"
echo ""

# Initialize JSON results file
mkdir -p "${OUTPUT_DIR}"
echo "{" > "${RESULT_FILE}"
echo "  \"benchmark\": \"RocksDB\"," >> "${RESULT_FILE}"
echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "${RESULT_FILE}"
echo "  \"results\": [" >> "${RESULT_FILE}"

FIRST_RESULT=true

# Function to run benchmark for a specific workload and database directory
run_benchmark() {
    local workload=$1
    local name=$2
    local db_dir=$3

    echo -e "${YELLOW}----------------------------------------${NC}"
    echo -e "${YELLOW}Testing: ${name} - ${workload}${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    echo ""

    # Clean up existing database directory
    if [ -d "${db_dir}" ]; then
        echo -e "${YELLOW}Cleaning up existing database directory...${NC}"
        rm -rf "${db_dir}"
    fi

    mkdir -p "${db_dir}"

    # Load phase
    echo -e "${GREEN}[1/2] Loading data...${NC}"
    "${YCSB_BIN}" load -P "${WORKLOAD_DIR}/${workload}" -p recordcount=${RECORD_COUNT} -p operationcount=${OPERATION_COUNT} -db "${db_dir}"

    echo ""

    # Run phase
    echo -e "${GREEN}[2/2] Running benchmark...${NC}"
    local output=$(mktemp)
    "${YCSB_BIN}" run -P "${WORKLOAD_DIR}/${workload}" -p recordcount=${RECORD_COUNT} -p operationcount=${OPERATION_COUNT} -db "${db_dir}" 2>&1 | tee "${output}"

    echo ""

    # Extract throughput from output
    # Use tail -1 to ensure only the last line is captured (the final OVERALL Throughput)
    # Avoid capturing intermediate progress reports
    local throughput=$(grep "\[OVERALL\] Throughput:" "${output}" | tail -n 1 | sed -n 's/.*Throughput: \([0-9.]*\).*/\1/p')

    # Add result to JSON
    if [ "${FIRST_RESULT}" = true ]; then
        FIRST_RESULT=false
    else
        echo "    ," >> "${RESULT_FILE}"
    fi

    echo "    {" >> "${RESULT_FILE}"
    echo "      \"workload\": \"${workload}\"," >> "${RESULT_FILE}"
    echo "      \"filesystem\": \"${name}\"," >> "${RESULT_FILE}"
    echo "      \"throughput_ops_sec\": ${throughput:-0}" >> "${RESULT_FILE}"
    echo -n "    }" >> "${RESULT_FILE}"

    rm -f "${output}"
}

# Ensure filesystems are mounted and data roots exist
ensure_filesystems
CLEANUP_ENABLED=true
mkdir -p "${SWORNDISK_DATA_ROOT}" "${CRYPTDISK_DATA_ROOT}"

# Test each workload on both filesystems
for workload in "${WORKLOADS[@]}"; do
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Workload: ${workload}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # Test on SwornDisk
    run_benchmark "${workload}" "SwornDisk" "${SWORNDISK_DIR}"

    # Test on CryptDisk
    run_benchmark "${workload}" "CryptDisk" "${CRYPTDISK_DIR}"

    echo ""
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}All RocksDB benchmarks completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Tested workloads:"
for workload in "${WORKLOADS[@]}"; do
    echo "  - ${workload}"
done
echo ""

# Close JSON file
echo "" >> "${RESULT_FILE}"
echo "  ]" >> "${RESULT_FILE}"
echo "}" >> "${RESULT_FILE}"

echo -e "${GREEN}Results saved to: ${RESULT_FILE}${NC}"
echo ""

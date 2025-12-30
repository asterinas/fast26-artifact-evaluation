#!/bin/bash

# Script to run BoltDB benchmarks using go-ycsb
# Tests workloads a, b, e, f on SwornDisk and CryptDisk

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

YCSB_BIN="${SCRIPT_DIR}/go-ycsb/bin/go-ycsb"
WORKLOAD_DIR="${SCRIPT_DIR}/workloads"
RESULT_FILE="${OUTPUT_DIR}/boltdb_results.json"

# Check if go-ycsb binary exists
if [ ! -f "${YCSB_BIN}" ]; then
    echo -e "${RED}Error: go-ycsb binary not found at ${YCSB_BIN}${NC}"
    echo -e "${YELLOW}Please run: cd go-ycsb && make${NC}"
    exit 1
fi

# Check if workload directory exists
if [ ! -d "${WORKLOAD_DIR}" ]; then
    echo -e "${RED}Error: workload directory not found at ${WORKLOAD_DIR}${NC}"
    exit 1
fi

# Workloads to test
WORKLOADS=("workloada" "workloadb" "workloade" "workloadf")
RECORD_COUNT=100000
OPERATION_COUNT=100000

# Test database files (BoltDB is a single-file database)
SWORNDISK_FILE="${SWORNDISK_DATA_ROOT}/boltdb.db"
CRYPTDISK_FILE="${CRYPTDISK_DATA_ROOT}/boltdb.db"

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
echo -e "${BLUE}BoltDB Benchmark - go-ycsb${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Workloads to test: ${WORKLOADS[@]}"
echo "Results will be saved to: ${RESULT_FILE}"
echo ""

# Initialize JSON results file
mkdir -p "${OUTPUT_DIR}"
echo "{" > "${RESULT_FILE}"
echo "  \"benchmark\": \"BoltDB\"," >> "${RESULT_FILE}"
echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "${RESULT_FILE}"
echo "  \"results\": [" >> "${RESULT_FILE}"

FIRST_RESULT=true

# Function to run benchmark for a specific workload and database file
run_benchmark() {
    local workload=$1
    local name=$2
    local db_file=$3

    echo -e "${YELLOW}----------------------------------------${NC}"
    echo -e "${YELLOW}Testing: ${name} - ${workload}${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
    echo ""

    # Clean up existing database file
    if [ -f "${db_file}" ]; then
        echo -e "${YELLOW}Cleaning up existing database file...${NC}"
        rm -f "${db_file}"
    fi

    # Load phase
    echo -e "${GREEN}[1/2] Loading data...${NC}"
    "${YCSB_BIN}" load boltdb -P "${WORKLOAD_DIR}/${workload}" -p recordcount=${RECORD_COUNT} -p operationcount=${OPERATION_COUNT} -p bolt.path="${db_file}"

    echo ""

    # Run phase
    echo -e "${GREEN}[2/2] Running benchmark...${NC}"
    local output=$(mktemp)
    "${YCSB_BIN}" run boltdb -P "${WORKLOAD_DIR}/${workload}" -p recordcount=${RECORD_COUNT} -p operationcount=${OPERATION_COUNT} -p bolt.path="${db_file}" 2>&1 | tee "${output}"

    echo ""

    # Extract throughput from output
    # Use tail -1 to ensure only the last line is captured (the TOTAL line after "Run finished")
    # Avoid capturing intermediate progress reports (Takes 10s, Takes 20s...)
    local throughput=$(grep -i "TOTAL" "${output}" | tail -n 1 | sed -nE 's/.*(OPS|Ops\/Sec):\s*([0-9.]+).*/\2/p')

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
    run_benchmark "${workload}" "SwornDisk" "${SWORNDISK_FILE}"

    # Test on CryptDisk
    run_benchmark "${workload}" "CryptDisk" "${CRYPTDISK_FILE}"

    echo ""
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}All BoltDB benchmarks completed!${NC}"
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

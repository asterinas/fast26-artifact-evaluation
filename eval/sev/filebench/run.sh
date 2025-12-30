#!/bin/bash
set -e

# ============================================================
# DEVICE PATH CONFIGURATION (modify these paths as needed)
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"

# Mount points for filesystems
SWORNDISK_MOUNT="/mnt/sworndisk"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

# ============================================================
# Script Configuration
# ============================================================
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"

# Reset and mount scripts
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"
MOUNT_SCRIPT="${SCRIPT_DIR}/../mount_filesystems.sh"

# Workloads to test
WORKLOADS=("fileserver" "oltp" "varmail" "videoserver")

# Disk types to test
DISK_TYPES=("sworndisk" "cryptdisk")

# Block device paths
declare -A DEVICE_PATHS
DEVICE_PATHS["sworndisk"]="$SWORNDISK_DEVICE"
DEVICE_PATHS["cryptdisk"]="$CRYPTDISK_DEVICE"

# Mount points for each disk type
declare -A MOUNT_POINTS
MOUNT_POINTS["sworndisk"]="$SWORNDISK_MOUNT"
MOUNT_POINTS["cryptdisk"]="$CRYPTDISK_MOUNT"

# Test directory paths for each disk type (on mounted filesystems)
declare -A TEST_DIRS
TEST_DIRS["sworndisk"]="${SWORNDISK_MOUNT}/filebench-test"
TEST_DIRS["cryptdisk"]="${CRYPTDISK_MOUNT}/filebench-test"

function usage() {
    echo "Usage: $0 [workload]"
    echo "  workload: fileserver | oltp | varmail | videoserver | all (default: all)"
    exit 1
}

function check_filebench() {
    if ! command -v filebench &> /dev/null; then
        echo -e "${RED}Error: filebench not found.${NC}"
        echo -e "${YELLOW}You can install filebench by:${NC}"
        echo -e "  1. From package manager: ${GREEN}sudo apt install -y filebench${NC}"
        echo -e "  2. Build from source: ${GREEN}./download_and_build_filebench.sh${NC}"
        echo ""
        read -p "Would you like to build filebench from source now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "${SCRIPT_DIR}/download_and_build_filebench.sh"
        else
            exit 1
        fi
    fi
    echo -e "${GREEN}Found filebench: $(filebench -h 2>&1 | head -1 || echo 'installed')${NC}"
}

function check_mount_point() {
    local mountpoint=$1

    if ! mountpoint -q "$mountpoint"; then
        echo -e "${RED}Error: $mountpoint is not mounted${NC}"
        echo -e "${YELLOW}Please run mount_filesystems.sh first${NC}"
        return 1
    fi

    if [ ! -w "$mountpoint" ]; then
        echo -e "${RED}Error: $mountpoint is not writable${NC}"
        return 1
    fi

    echo -e "${GREEN}Mount point $mountpoint is accessible${NC}"
    return 0
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

function umount_filesystem() {
    local mountpoint=$1

    if ! mountpoint -q "$mountpoint"; then
        echo -e "${YELLOW}$mountpoint is not mounted, skipping umount${NC}"
        return 0
    fi

    echo -e "${YELLOW}Unmounting filesystem at $mountpoint...${NC}"
    umount "$mountpoint"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Filesystem unmounted successfully${NC}"
        sync
        sleep 1
        return 0
    else
        echo -e "${RED}Error: Failed to unmount filesystem${NC}"
        return 1
    fi
}

function remount_filesystem() {
    local disk_type=$1

    if [ ! -f "$MOUNT_SCRIPT" ]; then
        echo -e "${RED}Error: Mount script not found at $MOUNT_SCRIPT${NC}"
        return 1
    fi

    echo -e "${YELLOW}Remounting filesystem for $disk_type...${NC}"
    bash "$MOUNT_SCRIPT"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Filesystem remounted successfully${NC}"
        return 0
    else
        echo -e "${RED}Error: Failed to remount filesystem${NC}"
        return 1
    fi
}

function generate_workload_file() {
    local workload=$1
    local disk_type=$2
    local test_dir=${TEST_DIRS[$disk_type]}
    local template_file="${SCRIPT_DIR}/workloads/${workload}-template.f"
    local output_file="${SCRIPT_DIR}/workloads/${workload}-${disk_type}.f"

    if [ ! -e "${template_file}" ]; then
        echo -e "${RED}Template not found: ${template_file}${NC}"
        return 1
    fi

    # Remove old generated file to ensure we use latest template
    rm -f "${output_file}"

    # Replace placeholder with actual directory
    sed 's|\$BENCHMARK_DIR\$|'"${test_dir}"'|g' "${template_file}" > "${output_file}"

    # Output message to stderr so it doesn't interfere with return value
    echo -e "${GREEN}Generated workload file from template: ${workload}-${disk_type}.f${NC}" >&2
    echo "${workload}-${disk_type}.f"
}

function cleanup_test_dir() {
    local test_dir=$1
    echo -e "${YELLOW}Cleaning up test directory ${test_dir}...${NC}"
    rm -rf "$test_dir"
    mkdir -p "$test_dir"
    sync
    echo -e "${GREEN}Cleanup complete${NC}"
}

function run_filebench_test() {
    local disk_type=$1
    local workload=$2
    local workload_file=$3
    local test_dir=${TEST_DIRS[$disk_type]}
    local output_file="${OUTPUT_DIR}/${workload}_${disk_type}_output.txt"

    echo -e "${GREEN}Running filebench [${workload}] on ${disk_type}...${NC}"
    echo -e "${GREEN}Test directory: ${test_dir}${NC}"
    echo -e "${GREEN}Workload file: ${SCRIPT_DIR}/workloads/${workload_file}${NC}"

    # Create test directory if doesn't exist
    mkdir -p "$test_dir"

    # Run filebench
    filebench -f "${SCRIPT_DIR}/workloads/${workload_file}" 2>&1 | tee "${output_file}"
}

function run_single_workload() {
    local workload=$1

    for disk_type in "${DISK_TYPES[@]}"; do
        echo -e "\n${YELLOW}========== Testing ${workload} on ${disk_type} ==========${NC}\n"

        # Check if mount point is accessible
        local mountpoint=${MOUNT_POINTS[$disk_type]}
        if ! check_mount_point "$mountpoint"; then
            echo -e "${RED}Skipping ${disk_type} - mount point not accessible${NC}"
            continue
        fi

        # Generate workload file with correct path
        local workload_file=$(generate_workload_file "$workload" "$disk_type" 2>/dev/null)
        if [ $? -ne 0 ]; then
            continue
        fi

        # Clean up test directory before running
        cleanup_test_dir "${TEST_DIRS[$disk_type]}"

        # Run filebench test
        run_filebench_test "$disk_type" "$workload" "$workload_file"

        # Clean up test directory after running
        cleanup_test_dir "${TEST_DIRS[$disk_type]}"

        # Reset and remount for sworndisk
        if [ "$disk_type" == "sworndisk" ]; then
            echo -e "\n${YELLOW}Resetting and remounting sworndisk...${NC}"
            # Step 1: Unmount filesystem
            umount_filesystem "$mountpoint"
            # Step 2: Reset device
            reset_sworndisk
            # Step 3: Remount filesystem
            remount_filesystem "$disk_type"
        fi
    done
}

function main() {
    local selected_workload="${1:-all}"

    mkdir -p "${OUTPUT_DIR}"
    check_filebench

    echo -e "\n${YELLOW}========== Starting Filebench Benchmark ==========${NC}\n"
    echo -e "${YELLOW}Testing on mounted filesystems${NC}\n"

    # Ensure filesystems are mounted
    echo -e "${YELLOW}Checking filesystems...${NC}"
    if ! check_mount_point "${SWORNDISK_MOUNT}" || ! check_mount_point "${CRYPTDISK_MOUNT}"; then
        echo -e "\n${YELLOW}Filesystems not mounted. Mounting now...${NC}"
        remount_filesystem "all"
    fi

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
    local FINAL_RESULT_JSON="${OUTPUT_DIR}/result.json"
    echo -e "\n${YELLOW}Parsing benchmark results...${NC}"
    "${SCRIPT_DIR}/parse_filebench_results.sh" "${OUTPUT_DIR}" "${FINAL_RESULT_JSON}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}Benchmark complete!${NC}"
    echo -e "${GREEN}Results saved to ${FINAL_RESULT_JSON}${NC}"
    echo -e "${GREEN}========================================${NC}\n"

    echo -e "\n${YELLOW}To plot results, run:${NC}"
    echo -e "  python3 plot_result.py"
}

main "$@"

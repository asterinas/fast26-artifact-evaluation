#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
FIO_DIR="${SCRIPT_DIR}/../fio"
BOMFILE="${SCRIPT_DIR}/disk_age.yaml"
OUTPUT_DIR="${SCRIPT_DIR}/results"
RESULT_CSV="${OUTPUT_DIR}/reproduce_results.csv"

# Disk configuration
DISK_SIZE_GB=110
DISK_TYPES=("sworndisk" "cryptdisk")

# Test parameters
NUM_STEPS=9
STEP_GB=10

check_fio() {
    if [ ! -e ${FIO_DIR}/fio_src/fio ]; then
        echo -e "${RED}Error: fio not found. Building fio first...${NC}"
        (cd ${FIO_DIR} && ./download_and_build_fio.sh)
    fi
}

init_occlum_instance() {
    local instance_name=$1
    local disk_type=$2

    echo -e "${YELLOW}Initializing Occlum instance: ${instance_name} (${disk_type})...${NC}"

    rm -rf "${instance_name}"
    occlum new "${instance_name}"
    cd "${instance_name}"

    local TCS_NUM=$(($(nproc) * 2))

    new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} \
        --arg DISK_SIZE "${DISK_SIZE_GB}GB" \
        --arg DISK_NAME "$disk_type" '
        .resource_limits.user_space_size="1000MB" |
        .resource_limits.user_space_max_size = "1000MB" |
        .resource_limits.kernel_space_heap_size = "4000MB" |
        .resource_limits.kernel_space_heap_max_size="4000MB" |
        .resource_limits.max_num_of_threads = $THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {
            "disk_size": $DISK_SIZE,
            "disk_name": $DISK_NAME,
            "stat_waf": true,
            "enable_gc": false
        }}]' Occlum.json)"
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "$BOMFILE" --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

# Task 1: Run FIO with N steps to get throughput
run_fio_steps() {
    local instance_name=$1
    local filename=$2
    local output_file=$3

    echo -e "${GREEN}Task 1: Running FIO (${NUM_STEPS} steps x ${STEP_GB}GB)...${NC}"

    cd "${instance_name}"
    occlum run /bin/fio "/configs/rand-write-90g-10steps.fio" --filename="${filename}" 2>&1 | tee "${output_file}"
    cd ..
}

# Task 2: Run single FIO write to get WAF checkpoints (for sworndisk only)
run_fio_waf() {
    local instance_name=$1
    local filename=$2
    local size=$3
    local output_file=$4

    echo -e "${GREEN}Task 2: Running single FIO for WAF measurement...${NC}"

    cd "${instance_name}"
    occlum run /bin/fio "/configs/rand-write-4k.fio" --filename="${filename}" --size="${size}" 2>&1 | tee "${output_file}"
    cd ..
}

# Parse throughput for each step from FIO output
# Format: Run status group N (all jobs):
#         WRITE: bw=XXXMiB/s (XXXMB/s), XXXMiB/s-XXXMiB/s
parse_step_throughput() {
    local output_file=$1

    # Extract bandwidth from WRITE lines
    grep "WRITE:" "${output_file}" | grep "bw=" | sed -E 's/.*bw=([0-9.]+)MiB\/s.*/\1/' | awk '{if($1!="") print NR","$1}'
}

# Parse WAF checkpoints from output
parse_waf_checkpoints() {
    local output_file=$1
    grep "^WAF_CHECKPOINT:" "${output_file}" | sed 's/WAF_CHECKPOINT: //'
}

# Task 1 output: throughput data for each disk type
output_task1_results() {
    local output_file=$1
    local disk_type=$2
    local fixed_waf=$3  # WAF value (1.0 for cryptdisk, empty for sworndisk)

    parse_step_throughput "${output_file}" | while IFS=',' read -r step_num throughput; do
        local logical_gb=$((step_num * STEP_GB))
        local fill_percent=$(awk -v gb="$logical_gb" -v disk="$DISK_SIZE_GB" 'BEGIN {printf "%.0f", gb / disk * 100}')
        if [ -n "$fixed_waf" ]; then
            echo "${disk_type},${fill_percent},${logical_gb},${fixed_waf},${throughput}"
        fi
    done
}

# Task 2 output: WAF data for sworndisk, merge with step throughputs
output_task2_results() {
    local throughput_output=$1
    local waf_output=$2
    local disk_type=$3

    local tmp_tp=$(mktemp)
    local tmp_waf=$(mktemp)

    parse_step_throughput "${throughput_output}" > "${tmp_tp}"
    parse_waf_checkpoints "${waf_output}" > "${tmp_waf}"

    paste "${tmp_tp}" "${tmp_waf}" | while IFS=$'\t' read -r tp_line waf_line; do
        local throughput=$(echo "$tp_line" | cut -d',' -f2)
        local logical_gb=$(echo "$waf_line" | cut -d',' -f1)
        local waf=$(echo "$waf_line" | cut -d',' -f3)
        local fill_percent=$(awk -v gb="$logical_gb" -v disk="$DISK_SIZE_GB" 'BEGIN {printf "%.0f", gb / disk * 100}')
        echo "${disk_type},${fill_percent},${logical_gb},${waf},${throughput}"
    done

    rm -f "${tmp_tp}" "${tmp_waf}"
}

run_cryptdisk_test() {
    local disk_type="cryptdisk"
    local instance_name="occlum_instance"
    local filename="/dev/${disk_type}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Testing: ${disk_type}${NC}"
    echo -e "${GREEN}========================================${NC}"

    echo -e "${BLUE}Task 1 only (throughput), WAF fixed at 1.004${NC}"

    init_occlum_instance "$instance_name" "$disk_type"

    local output="${OUTPUT_DIR}/${disk_type}_task1_throughput.txt"
    run_fio_steps "$instance_name" "$filename" "$output"

    echo -e "${BLUE}Parsing throughput results...${NC}"
    output_task1_results "${output}" "$disk_type" "1.004" >> "$RESULT_CSV"

    rm -rf "$instance_name"
}

run_sworndisk_test() {
    local disk_type="sworndisk"
    local instance_name="occlum_instance_task1"
    local instance_name2="occlum_instance_task2"
    local filename="/dev/${disk_type}"

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Testing: ${disk_type}${NC}"
    echo -e "${GREEN}========================================${NC}"

    # Task 1: Throughput with steps
    echo -e "${BLUE}Task 1: Measuring throughput (${NUM_STEPS} steps)${NC}"
    init_occlum_instance "$instance_name" "$disk_type"

    local output1="${OUTPUT_DIR}/${disk_type}_task1_throughput.txt"
    run_fio_steps "$instance_name" "$filename" "$output1"

    rm -rf "$instance_name"

    # Task 2: WAF with single write
    echo -e "${BLUE}Task 2: Measuring WAF (single run)${NC}"
    init_occlum_instance "$instance_name2" "$disk_type"

    local total_bytes=$((NUM_STEPS * STEP_GB * 1024 * 1024 * 1024))
    local output2="${OUTPUT_DIR}/${disk_type}_task2_waf.txt"
    run_fio_waf "$instance_name2" "$filename" "$total_bytes" "$output2"

    rm -rf "$instance_name2"

    # Merge results
    echo -e "${BLUE}Merging throughput and WAF results...${NC}"
    output_task2_results "${output1}" "${output2}" "$disk_type" >> "$RESULT_CSV"
}

main() {
    mkdir -p "${OUTPUT_DIR}"
    check_fio

    echo "disk_type,fill_percent,logical_gb,waf,throughput_mib_s" > "$RESULT_CSV"
    echo -e "${GREEN}Initialized CSV file: ${RESULT_CSV}${NC}"

    # Run SwornDisk first (throughput + WAF)
    run_sworndisk_test

    # Run CryptDisk (throughput only, WAF=1.0)
    run_cryptdisk_test

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Disk Utility Experiment Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Results: ${RESULT_CSV}"
}

main "$@"

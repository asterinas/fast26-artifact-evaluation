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
DISK_SIZE_GB=50
DISK_TYPES=("sworndisk" "cryptdisk")

# Aging parameters
FILL_STEP_PERCENT=10   # Fill 10% of disk at each step
MAX_FILL_PERCENT=90    # Stop at 90% full

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
        .resource_limits.kernel_space_heap_size = "2000MB" |
        .resource_limits.kernel_space_heap_max_size="2000MB" |
        .resource_limits.max_num_of_threads = $THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {
            "disk_size": $DISK_SIZE,
            "disk_name": $DISK_NAME,
            "stat_waf": true
        }}]' Occlum.json)"
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "$BOMFILE" --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

run_fio() {
    local instance_name=$1
    local fio_config=$2
    local filename=$3
    local size=$4
    local output_file=$5

    echo -e "${GREEN}Running fio ${fio_config} (filename=${filename}, size=${size})...${NC}"

    cd "${instance_name}"
    occlum run /bin/fio "/configs/${fio_config}" --filename="${filename}" --size="${size}" 2>&1 | tee "${output_file}"
    cd ..
}

run_rand_write() {
    local instance_name=$1
    local filename=$2
    local size=$3
    local output_file=$4

    echo -e "${GREEN}Running random write test (size=${size})...${NC}"

    cd "${instance_name}"
    occlum run /bin/fio "/configs/rand-write-4k.fio" --filename="${filename}" --size="${size}" 2>&1 | tee "${output_file}"
    cd ..
}

calculate_size() {
    local fill_percent=$1
    local disk_size_bytes=$((DISK_SIZE_GB * 1024 * 1024 * 1024))
    local fill_bytes=$((disk_size_bytes * fill_percent / 100))
    echo $fill_bytes
}

parse_bw() {
    local output_file=$1
    local metric_field

    metric_field=$(grep "WRITE:" "${output_file}" | awk '{print $2}' | head -n1 || true)

    local value
    value=$(echo ${metric_field} | awk '{print $1}' | sed 's#bw=##;s#MiB/s.*##')

    if [ -z "${value}" ]; then
        echo "0"
        return
    fi

    echo "${value}"
}

parse_waf() {
    local output_file=$1
    local waf

    waf=$(grep -oP 'WAF:\s+\K[0-9.]+' "${output_file}" | tail -1 || true)

    if [ -z "$waf" ]; then
        echo "N/A"
    else
        echo "$waf"
    fi
}

run_experiment_for_disk() {
    local disk_type=$1

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Testing Disk Type: ${disk_type}${NC}"
    echo -e "${GREEN}========================================${NC}"

    local instance_name="occlum_instance"
    local filename="/dev/${disk_type}"

    for fill_percent in $(seq $FILL_STEP_PERCENT $FILL_STEP_PERCENT $MAX_FILL_PERCENT); do
        echo -e "\n${BLUE}========== ${disk_type} | Fill Level: ${fill_percent}% ==========${NC}"

        local fill_size_bytes=$(calculate_size $fill_percent)

        # Initialize instance for this test
        init_occlum_instance "$instance_name" "$disk_type"

        # Random write to fill disk to target utilization
        local output="${OUTPUT_DIR}/${disk_type}_fill_${fill_percent}_rand.txt"
        run_rand_write "$instance_name" "$filename" "$fill_size_bytes" "$output"

        local throughput=$(parse_bw "$output")
        local waf=$(parse_waf "$output")

        echo "${disk_type},${fill_percent},${throughput},${waf}" >> "$RESULT_CSV"
        echo -e "${GREEN}✓ ${disk_type} | Fill ${fill_percent}% | ${throughput} MiB/s | WAF: ${waf}${NC}"

        # Clean up instance for next iteration
        echo -e "${YELLOW}Cleaning up instance...${NC}"
        rm -rf "$instance_name"
    done
}

main() {
    mkdir -p "${OUTPUT_DIR}"
    check_fio

    echo "disk_type,fill_percent,throughput_mib_s,waf" > "$RESULT_CSV"
    echo -e "${GREEN}Initialized CSV file: ${RESULT_CSV}${NC}"

    for disk_type in "${DISK_TYPES[@]}"; do
        run_experiment_for_disk "$disk_type"
    done

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  Disk Utility Experiment Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Disk Size: ${DISK_SIZE_GB}GB"
    echo -e "Disk Types: ${DISK_TYPES[*]}"
    echo -e "Fill Step: ${FILL_STEP_PERCENT}%"
    echo -e "Results: ${RESULT_CSV}"
}

main "$@"

#!/bin/bash
set -eo pipefail

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
BOMFILE=${SCRIPT_DIR}/cache_size.yaml
OUTPUT_DIR="${SCRIPT_DIR}/results"
RESULT_JSON="${OUTPUT_DIR}/cache_size_result.json"

# Cache sizes (MB) to test
CACHE_SIZES_MB=(256 512 768 1024 1280 1536)

# Disk types to test
DISK_TYPES=("pfsdisk" "sworndisk" "cryptdisk")

# Current disk type (set by outer loop)
DISK_TYPE=""

# Write paths for each disk type (block device)
declare -A WRITE_PATHS
WRITE_PATHS["pfsdisk"]="/root/test"
WRITE_PATHS["sworndisk"]="/dev/sworndisk"
WRITE_PATHS["cryptdisk"]="/dev/cryptdisk"

# Read path (ext2 filesystem)
READ_PATH="/ext2/fio-test"

check_fio() {
    if [ ! -e "${SCRIPT_DIR}/../fio/fio_src/fio" ]; then
        echo "Error: fio not found. Building fio first..."
        (cd "${SCRIPT_DIR}/../fio" && ./download_and_build_fio.sh)
    fi
}

init_occlum_instance() {
    local instance_name=$1
    local cache_size_mb=$2

    echo -e "${YELLOW}Initializing Occlum instance: ${instance_name} (disk=${DISK_TYPE}, cache_size=${cache_size_mb}MB)...${NC}"

    rm -rf "${instance_name}"
    occlum new "${instance_name}"
    cd "${instance_name}"

    local TCS_NUM=$(($(nproc) * 2))

    if [ "$DISK_TYPE" == "pfsdisk" ]; then
        # PfsDisk: only set cache_size for ROOT_FS SEFS layers, no ext2 mount
        new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} \
            --argjson CACHE_SIZE_MB "$cache_size_mb" '
            .resource_limits.user_space_size="2000MB" |
            .resource_limits.user_space_max_size = "2000MB" |
            .resource_limits.kernel_space_heap_size = "2000MB" |
            .resource_limits.kernel_space_heap_max_size="2000MB" |
            .resource_limits.max_num_of_threads = $THREAD_NUM |
            .mount[0].options.layers[0].options.cache_size = ($CACHE_SIZE_MB | tostring + "MB") |
            .mount[0].options.layers[1].options.cache_size = ($CACHE_SIZE_MB | tostring + "MB")
            ' Occlum.json)"
    else
        # sworndisk/cryptdisk: only set cache_size for ext2 mount, not ROOT_FS
        new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} \
            --arg DISK_NAME "$DISK_TYPE" \
            --argjson CACHE_SIZE_MB "$cache_size_mb" '
            .resource_limits.user_space_size="4000MB" |
            .resource_limits.user_space_max_size = "4000MB" |
            .resource_limits.kernel_space_heap_size = "4000MB" |
            .resource_limits.kernel_space_heap_max_size="4000MB" |
            .resource_limits.max_num_of_threads = $THREAD_NUM |
            .mount += [{"target": "/ext2", "type": "ext2", "options": {
                "disk_size": "60GB",
                "disk_name": $DISK_NAME,
                "cache_size": ($CACHE_SIZE_MB | tostring + "MB")
            }}]' Occlum.json)"
    fi

    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f "$BOMFILE" --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

run_fio() {
    local instance_name=$1
    local fio_config=$2
    local output_file=$3
    local test_path=$4

    echo -e "${GREEN}Running fio ${fio_config} (file: ${test_path})...${NC}"

    cd "${instance_name}"
    occlum run /bin/fio --filename="${test_path}" "/configs/${fio_config}" 2>&1 | tee "${output_file}"
    cd ..
}

parse_bw() {
    local output_file=$1
    local mode=$2
    local metric_field

    if [ "$mode" == "write" ]; then
        metric_field=$(grep "WRITE:" "${output_file}" | awk '{print $2}' | head -n1 || true)
    else
        metric_field=$(grep "READ:" "${output_file}" | awk '{print $2}' | head -n1 || true)
    fi

    local value
    value=$(echo ${metric_field} | awk '{print $1}' | sed 's#bw=##;s#MiB/s.*##')

    if [ -z "${value}" ]; then
        echo "Failed to parse ${mode} bandwidth from ${output_file}" >&2
        return 1
    fi

    echo "${value}"
}

main() {
    mkdir -p "${OUTPUT_DIR}"
    check_fio

    local results=()

    for DISK_TYPE in "${DISK_TYPES[@]}"; do
        echo -e "\n${BLUE}########## Testing Disk Type: ${DISK_TYPE} ##########${NC}\n"

        # Set paths based on disk type
        local write_path=${WRITE_PATHS[$DISK_TYPE]}
        local read_path
        if [ "$DISK_TYPE" == "pfsdisk" ]; then
            read_path="/root/test"
        else
            read_path="$READ_PATH"
        fi

        for cache in "${CACHE_SIZES_MB[@]}"; do
            if [ "$DISK_TYPE" == "pfsdisk" ]; then
                # PfsDisk: run write then read in the same instance (reuse file)
                echo -e "${BLUE}========== PfsDisk Test: cache=${cache}MB ==========${NC}"
                init_occlum_instance "occlum_instance" "$cache"

                # Write test
                echo -e "${BLUE}--- Write Test ---${NC}"
                local write_output="${OUTPUT_DIR}/${DISK_TYPE}_cache${cache}_randwrite.txt"
                run_fio "occlum_instance" "rand-write-4k.fio" "$write_output" "$write_path"
                local write_bw
                write_bw=$(parse_bw "$write_output" "write")
                results+=("{\"disk_type\":\"${DISK_TYPE}\",\"cache_size_mb\":${cache},\"op\":\"write\",\"throughput_mib_s\":${write_bw}}")

                # Read test (same instance, reuse file)
                echo -e "${BLUE}--- Read Test ---${NC}"
                local read_output="${OUTPUT_DIR}/${DISK_TYPE}_cache${cache}_randread.txt"
                run_fio "occlum_instance" "rand-read-4k.fio" "$read_output" "$read_path"
                local read_bw
                read_bw=$(parse_bw "$read_output" "read")
                results+=("{\"disk_type\":\"${DISK_TYPE}\",\"cache_size_mb\":${cache},\"op\":\"read\",\"throughput_mib_s\":${read_bw}}")

                echo -e "${BLUE}Cleaning up occlum_instance...${NC}"
                rm -rf "occlum_instance"
            else
                # sworndisk/cryptdisk: create separate instances for write and read
                # Write uses block device, read uses ext2 filesystem

                # 1. Random write test (block device)
                echo -e "${BLUE}========== ${DISK_TYPE} Write Test: cache=${cache}MB ==========${NC}"
                init_occlum_instance "occlum_instance" "$cache"
                local write_output="${OUTPUT_DIR}/${DISK_TYPE}_cache${cache}_randwrite.txt"
                run_fio "occlum_instance" "rand-write-4k.fio" "$write_output" "$write_path"
                local write_bw
                write_bw=$(parse_bw "$write_output" "write")
                results+=("{\"disk_type\":\"${DISK_TYPE}\",\"cache_size_mb\":${cache},\"op\":\"write\",\"throughput_mib_s\":${write_bw}}")

                echo -e "${BLUE}Cleaning up occlum_instance...${NC}"
                rm -rf "occlum_instance"

                # 2. Random read test (ext2 filesystem)
                echo -e "${BLUE}========== ${DISK_TYPE} Read Test: cache=${cache}MB ==========${NC}"
                init_occlum_instance "occlum_instance" "$cache"
                local read_output="${OUTPUT_DIR}/${DISK_TYPE}_cache${cache}_randread.txt"
                run_fio "occlum_instance" "rand-read-4k.fio" "$read_output" "$read_path"
                local read_bw
                read_bw=$(parse_bw "$read_output" "read")
                results+=("{\"disk_type\":\"${DISK_TYPE}\",\"cache_size_mb\":${cache},\"op\":\"read\",\"throughput_mib_s\":${read_bw}}")

                echo -e "${BLUE}Cleaning up occlum_instance...${NC}"
                rm -rf "occlum_instance"
            fi
        done
    done

    echo "[" > "${RESULT_JSON}"
    for i in "${!results[@]}"; do
        if [ $i -gt 0 ]; then echo "," >> "${RESULT_JSON}"; fi
        echo "  ${results[$i]}" >> "${RESULT_JSON}"
    done
    echo "]" >> "${RESULT_JSON}"

    echo -e "\n${GREEN}Cache size benchmark complete! Results saved to ${RESULT_JSON}${NC}"
    cat "${RESULT_JSON}"
}

main "$@"

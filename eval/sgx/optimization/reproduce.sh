#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
bomfile=${SCRIPT_DIR}/optimization.yaml
RESULTS_DIR=${SCRIPT_DIR}/results
RESULT_JSON="${RESULTS_DIR}/optimization_results.json"

FIO=fio

# Check if fio is built
if [ ! -e ${SCRIPT_DIR}/../fio/fio_src/${FIO} ]; then
    echo "Error: cannot find '${FIO}' in ../fio/fio_src/"
    echo "Please build fio first by running:"
    echo "  cd ../fio && ./download_and_build_fio.sh"
    exit 1
fi

# Create results directory
mkdir -p ${RESULTS_DIR}

# Function to init occlum instance with specific optimization flags
init_occlum_instance() {
    local two_level_caching=$1
    local delayed_reclamation=$2
    local cache_size=${3:-}

    cd ${SCRIPT_DIR}
    rm -rf occlum_instance && occlum new occlum_instance
    cd occlum_instance

    local TCS_NUM=$(($(nproc) * 2))

    new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} \
                   --argjson TWO_LEVEL_CACHING ${two_level_caching} \
                   --argjson DELAYED_RECLAMATION ${delayed_reclamation} \
                   --arg CACHE_SIZE "${cache_size}" '
        .resource_limits.user_space_size="2000MB" |
        .resource_limits.user_space_max_size = "2000MB" |
        .resource_limits.kernel_space_heap_size = "2000MB" |
        .resource_limits.kernel_space_heap_max_size="2000MB" |
        .resource_limits.max_num_of_threads = $THREAD_NUM |
        .mount += [{
            "target": "/ext2",
            "type": "ext2",
            "options": (
                {
                    "disk_size": "50GB",
                    "disk_name": "sworndisk",
                    "two_level_caching": $TWO_LEVEL_CACHING,
                    "delayed_reclamation": $DELAYED_RECLAMATION
                }
                + (if $CACHE_SIZE != "" then {"cache_size": $CACHE_SIZE} else {} end)
            )
        }]' Occlum.json)" && \
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f $bomfile --root image --include-dir /opt/occlum/etc/template
    occlum build
}

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Optimization Benchmark with FIO${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

parse_throughput_mib() {
    local log_file=$1
    local mode=$2 # read or write
    local field
    if [ "$mode" == "write" ]; then
        field=$(grep "WRITE:" "$log_file" | awk '{print $2}' | tail -1)
    else
        field=$(grep "READ:" "$log_file" | awk '{print $2}' | tail -1)
    fi
    echo $(echo "$field" | awk '{print $1}' | sed 's/bw=//;s/MiB\/s.*//')
}

run_fio() {
    local config=$1
    local output=$2
    cd ${SCRIPT_DIR}/occlum_instance
    echo -e "${GREEN}Running: occlum run /bin/${FIO} /configs/${config}${NC}"
    occlum run /bin/${FIO} "/configs/${config}" 2>&1 | tee ${output}
    cd ${SCRIPT_DIR}
}

results=()

# Test 1: delayed_reclamation impact on 4K random write
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Test 1: delayed_reclamation (4K Random Write)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

for DELAYED_REC in true false; do
    TEST_NAME="rand-write-4k-delayed_reclamation_${DELAYED_REC}"
    echo -e "${YELLOW}Running 4K random write with delayed_reclamation=${DELAYED_REC}...${NC}"

    # Init with two_level_caching=false (not relevant for write test), no cache_size override
    init_occlum_instance false ${DELAYED_REC} ""

    run_fio "rand-write-4k.fio" "${RESULTS_DIR}/${TEST_NAME}.log"

    local_log="${RESULTS_DIR}/${TEST_NAME}.log"
    local_bw=$(parse_throughput_mib "$local_log" "write")
    results+=("{\"type\":\"write\",\"delayed_reclamation\":${DELAYED_REC},\"throughput_mib_s\":${local_bw:-0}}")

    echo ""
    echo -e "${GREEN}${TEST_NAME} test completed.${NC}"
    echo ""
done

echo ""

# Test 2: two_level_caching impact on 4K random read
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Test 2: two_level_caching (4K Random Read)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

for TWO_LEVEL_CACHE in false true; do
    TEST_NAME="rand-read-4k-two_level_caching_${TWO_LEVEL_CACHE}"
    echo -e "${YELLOW}Running 4K random read with two_level_caching=${TWO_LEVEL_CACHE}...${NC}"

    # Init with delayed_reclamation=false (not relevant for read test), set cache_size
    init_occlum_instance ${TWO_LEVEL_CACHE} false "1GB"

    run_fio "rand-read-4k.fio" "${RESULTS_DIR}/${TEST_NAME}.log"

    local_log="${RESULTS_DIR}/${TEST_NAME}.log"
    local_bw=$(parse_throughput_mib "$local_log" "read")
    results+=("{\"type\":\"read\",\"two_level_caching\":${TWO_LEVEL_CACHE},\"throughput_mib_s\":${local_bw:-0}}")

    echo ""
    echo -e "${GREEN}${TEST_NAME} test completed.${NC}"
    echo ""
done

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  All optimization tests completed!${NC}"
echo -e "${GREEN}  Results directory: ${RESULTS_DIR}${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Performance comparison:"
echo "  - delayed_reclamation: Compare rand-write-4k logs"
echo "  - two_level_caching: Compare rand-read-4k logs"
echo ""
echo "Saving JSON summary..."
echo "[" > "${RESULT_JSON}"
for i in "${!results[@]}"; do
    if [ $i -gt 0 ]; then echo "," >> "${RESULT_JSON}"; fi
    echo "  ${results[$i]}" >> "${RESULT_JSON}"
done
echo "]" >> "${RESULT_JSON}"
echo "JSON summary saved to ${RESULT_JSON}"

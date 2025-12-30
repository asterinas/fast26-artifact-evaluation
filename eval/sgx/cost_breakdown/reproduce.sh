#!/bin/bash
set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
bomfile=${SCRIPT_DIR}/cost.yaml
RESULTS_DIR=${SCRIPT_DIR}/results

FIO=fio

if [ ! -e ${SCRIPT_DIR}/../fio/fio_src/${FIO} ]; then
    echo "Error: cannot stat '${FIO}' in ../fio/fio_src"
    echo "Please run: cd ../fio && ./download_and_build_fio.sh"
    exit 1
fi

mkdir -p ${RESULTS_DIR}

init_occlum_instance() {
    cd ${SCRIPT_DIR}
    rm -rf occlum_instance && occlum new occlum_instance
    cd occlum_instance
    TCS_NUM=$(($(nproc) * 2))
    new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} '.resource_limits.user_space_size="2000MB" |
        .resource_limits.user_space_max_size = "2000MB" |
        .resource_limits.kernel_space_heap_size = "2000MB" |
        .resource_limits.kernel_space_heap_max_size="2000MB" |
        .resource_limits.max_num_of_threads = $THREAD_NUM |
        .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": "50GB", "disk_name": "sworndisk", "stat_cost": true}}]' Occlum.json)" && \
    echo "${new_json}" > Occlum.json

    rm -rf image
    copy_bom -f $bomfile --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ${SCRIPT_DIR}
}

run_fio() {
    local config=$1
    local output=$2
    cd ${SCRIPT_DIR}/occlum_instance
    echo -e "${GREEN}Running: occlum run /bin/${FIO} /configs/${config}${NC}"
    occlum run /bin/${FIO} "/configs/${config}" 2>&1 | tee ${output}
    cd ${SCRIPT_DIR}
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Cost Statistics Benchmark${NC}"
echo -e "${BLUE}========================================${NC}"

# Sequential Write Test
echo -e "\n${YELLOW}[1/4] Sequential Write Test${NC}"
init_occlum_instance
run_fio "seq-write.fio" "${RESULTS_DIR}/seq-write.log"

# Random Write Test
echo -e "\n${YELLOW}[2/4] Random Write Test${NC}"
init_occlum_instance
run_fio "rand-write.fio" "${RESULTS_DIR}/rand-write.log"

# Sequential Read Test (needs layout first)
echo -e "\n${YELLOW}[3/4] Sequential Read Test${NC}"
init_occlum_instance
echo -e "${YELLOW}  Phase 1: Layout (writing data)...${NC}"
run_fio "seq-read-layout.fio" "${RESULTS_DIR}/seq-read-layout.log"
echo -e "${YELLOW}  Phase 2: Sequential Read...${NC}"
run_fio "seq-read.fio" "${RESULTS_DIR}/seq-read.log"

# Random Read Test (needs layout first)
echo -e "\n${YELLOW}[4/4] Random Read Test${NC}"
init_occlum_instance
echo -e "${YELLOW}  Phase 1: Layout (writing data)...${NC}"
run_fio "rand-read-layout.fio" "${RESULTS_DIR}/rand-read-layout.log"
echo -e "${YELLOW}  Phase 2: Random Read...${NC}"
run_fio "rand-read.fio" "${RESULTS_DIR}/rand-read.log"

# Cleanup
cd ${SCRIPT_DIR}
rm -rf occlum_instance

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  All tests completed!${NC}"
echo -e "${GREEN}  Results: ${RESULTS_DIR}${NC}"
echo -e "${GREEN}========================================${NC}"


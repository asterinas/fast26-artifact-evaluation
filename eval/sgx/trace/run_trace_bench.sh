#!/bin/bash
set -e

g++ trace.cpp -std=c++11 -o trace

GREEN='\033[1;32m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
bomfile=${SCRIPT_DIR}/trace.yaml

CONFIG=$1

# 1. Init Occlum instance
rm -rf occlum_instance && occlum new occlum_instance
cd occlum_instance
TCS_NUM=$(($(nproc) * 2))
new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} '.resource_limits.user_space_size="5000MB" |
    .resource_limits.user_space_max_size = "5000MB" |
    .resource_limits.kernel_space_heap_size="5000MB" |
    .resource_limits.kernel_space_heap_max_size="5000MB" |
    .resource_limits.max_num_of_threads = $THREAD_NUM |
    .mount += [{"target": "/ext2", "type": "ext2", "options": {"disk_size": "60GB","disk_name":"sworndisk"}}]' Occlum.json)" && \
echo "${new_json}" > Occlum.json

# 2. Copy files into Occlum instance and build
rm -rf image
copy_bom -f $bomfile --root image --include-dir /opt/occlum/etc/template

occlum build

# 3. Run the program
echo -e "${GREEN}occlum run /bin/trace /dev/sworndisk /msr-test/${CONFIG}${NC}"
occlum run /bin/trace /dev/sworndisk /msr-test/${CONFIG}.csv
# occlum run /bin/trace /root/msr-test /msr-test/${CONFIG}.csv

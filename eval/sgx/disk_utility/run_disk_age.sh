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
RESULT_CSV="${OUTPUT_DIR}/disk_age_results.csv"
RESULT_JSON="${OUTPUT_DIR}/disk_age_results.json"

# Disk configuration
DISK_SIZE_GB=50
DISK_TYPES=("sworndisk" "cryptdisk")
TEST_PATH="/ext2/disk-age-test"

# Aging parameters
FILL_STEP_PERCENT=10  # Fill 10% of disk at each step
MAX_FILL_PERCENT=90   # Stop at 90% full

# Test configuration
FILL_METHOD="rand-write"    # Use random write to fill disk
TEST_METHOD="rand-write"   # Use random write to test performance

function check_fio() {
    if [ ! -e ${FIO_DIR}/fio_src/fio ]; then
        echo -e "${RED}Error: fio not found. Building fio first...${NC}"
        cd ${FIO_DIR}
        ./download_and_build_fio.sh
        cd ${SCRIPT_DIR}
    fi
}

function init_occlum_instance() {
    local instance_name=${1:-"occlum_instance"}
    local disk_name=${2:-"sworndisk"}

    echo -e "${YELLOW}Initializing Occlum instance: ${instance_name}...${NC}"

    rm -rf ${instance_name} && occlum new ${instance_name}
    cd ${instance_name}

    TCS_NUM=$(($(nproc) * 2))

    # Configure Occlum with ext2 mount for SwornDisk
    new_json="$(jq --argjson THREAD_NUM ${TCS_NUM} \
        --arg DISK_SIZE "${DISK_SIZE_GB}GB" \
        --arg DISK_NAME "$disk_name" '
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
    copy_bom -f $BOMFILE --root image --include-dir /opt/occlum/etc/template
    occlum build
    cd ..
}

function calculate_size() {
    local fill_percent=$1
    local disk_size_bytes=$((DISK_SIZE_GB * 1024 * 1024 * 1024))
    local fill_bytes=$((disk_size_bytes * fill_percent / 100))
    echo $fill_bytes
}

function fill_disk() {
    local instance_name=$1
    local fill_percent=$2
    local size_bytes=$3

    echo -e "${BLUE}Filling disk to ${fill_percent}% (writing $((size_bytes / 1024 / 1024 / 1024))GB)...${NC}"

    cd ${instance_name}
    # Run fill operation, suppress WAF stats output (we only care about test phase WAF)
    occlum run /bin/fio \
        --filename="${TEST_PATH}" \
        --size=${size_bytes} \
        "/configs/disk_age_seq_write.fio" > /dev/null 2>&1

    cd ..

    echo -e "${GREEN}Disk filled to ${fill_percent}%${NC}"
}

function fill_and_test_performance() {
    local instance_name=$1
    local fill_percent=$2
    local fill_size_bytes=$3
    local test_size_bytes=$4

    echo -e "${BLUE}Filling disk to ${fill_percent}% ($(($fill_size_bytes / 1024 / 1024 / 1024))GB) and testing...${NC}" >&2

    cd ${instance_name}

    # Create a compound fio job file that runs fill then test in one execution
    cat > image/configs/fill_and_test.fio <<EOF
# Compound job: fill disk then test performance
# This runs in a single fio execution, so WAF stats are cumulative

[global]
ioengine=sync
thread=1
numjobs=1
direct=1
fsync_on_close=1
time_based=0

# Job 1: Fill disk with random writes
[fill-rand-write]
rw=randwrite
bs=4k
filename=${TEST_PATH}
size=${fill_size_bytes}

# Job 2: Test performance with random writes
[test-rand-write]
rw=randwrite
bs=4k
filename=${TEST_PATH}-perf
size=${test_size_bytes}
EOF

    occlum build > /dev/null 2>&1

    echo -e "${GREEN}Running compound test (fill + performance test)...${NC}" >&2

    # Run the compound fio job (both fill and test in one execution, cumulative WAF)
    local output=$(occlum run /bin/fio /configs/fill_and_test.fio 2>&1)

    # Print WAF stats to stderr
    echo "$output" | grep -A5 "WAF Statistics" >&2 || true

    cd ..

    # Parse throughput from the second job (test-rand-write) output
    # Look for the last WRITE: line which should be from the random write test
    local throughput=$(echo "$output" | grep -oP 'WRITE:.*bw=\K[0-9.]+[KMGT]?i?B/s' | tail -1)
    if [ -z "$throughput" ]; then
        throughput=$(echo "$output" | grep -oP 'bw=\K[0-9.]+[KMGT]?i?B/s' | tail -1)
    fi
    if [ -z "$throughput" ]; then
        echo -e "${RED}Warning: Failed to parse throughput from FIO output${NC}" >&2
        echo -e "${RED}FIO output (last 1000 chars):${NC}" >&2
        echo "$output" | tail -c 1000 >&2
        throughput="0"
    fi

    # Parse WAF from output
    local waf=$(echo "$output" | grep -oP 'WAF:\s+\K[0-9.]+' | tail -1)
    if [ -z "$waf" ]; then
        waf="N/A"
    fi

    # Return both throughput and WAF (only this line goes to stdout)
    echo "${throughput},${waf}"
}


function test_performance() {
    local instance_name=$1
    local fill_percent=$2
    local test_size_bytes=$3

    echo -e "${BLUE}Testing random write performance at ${fill_percent}% fill...${NC}"

    cd ${instance_name}
    # Capture all output including WAF stats printed at exit
    local output=$(occlum run /bin/fio \
        --filename="${TEST_PATH}-perf" \
        --size=${test_size_bytes} \
        "/configs/disk_age_rand_write.fio" 2>&1)

    # Print WAF stats to stderr (so it doesn't interfere with return value)
    echo "$output" | grep -A5 "WAF Statistics" >&2 || true

    cd ..

    # Parse throughput from fio output (try multiple patterns)
    local throughput=$(echo "$output" | grep -oP 'WRITE:.*bw=\K[0-9.]+[KMGT]?i?B/s' | head -1)

    # If first pattern fails, try alternative patterns
    if [ -z "$throughput" ]; then
        throughput=$(echo "$output" | grep -oP 'bw=\K[0-9.]+[KMGT]?i?B/s' | head -1)
    fi

    if [ -z "$throughput" ]; then
        echo -e "${RED}Warning: Failed to parse throughput from FIO output${NC}" >&2
        throughput="0"
    fi

    # Parse WAF from output
    local waf=$(echo "$output" | grep -oP 'WAF:\s+\K[0-9.]+' | tail -1)
    if [ -z "$waf" ]; then
        waf="N/A"
    fi

    # Return both throughput and WAF (separated by comma)
    echo "${throughput},${waf}"
}

function parse_throughput_to_mbs() {
    local throughput_str=$1

    if [ -z "$throughput_str" ] || [ "$throughput_str" = "0" ]; then
        echo "0"
        return
    fi

    # Extract number and unit
    local value=$(echo "$throughput_str" | grep -oP '^[0-9.]+')
    local unit=$(echo "$throughput_str" | grep -oP '[KMGT]?i?B/s$')

    # Handle empty value
    if [ -z "$value" ]; then
        echo "0"
        return
    fi

    # Convert to MB/s
    case $unit in
        "KiB/s"|"KB/s")
            echo "scale=2; $value / 1024" | bc
            ;;
        "MiB/s"|"MB/s")
            echo "$value"
            ;;
        "GiB/s"|"GB/s")
            echo "scale=2; $value * 1024" | bc
            ;;
        "B/s")
            echo "scale=2; $value / 1024 / 1024" | bc
            ;;
        *)
            echo -e "${YELLOW}Warning: Unknown unit '$unit', returning raw value${NC}" >&2
            echo "$value"
            ;;
    esac
}

function run_aging_experiment() {
    local disk_name=$1
    echo -e "${GREEN}========== Starting Disk Aging Experiment ==========${NC}"
    echo -e "${YELLOW}Disk Type: ${disk_name}${NC}"
    echo -e "${YELLOW}Strategy: Random write to fill disk, random write to test performance${NC}"
    echo -e "${YELLOW}WAF Measurement: Cumulative (includes both fill and test operations)${NC}"
    echo -e "${YELLOW}Note: Each test uses a fresh Occlum instance to avoid interference${NC}\n"

    # Initialize CSV file with header
    # Performance test size (1GB for random write test)
    local test_size_bytes=$((1 * 1024 * 1024 * 1024))

    # Cumulative fill size (total data written so far)
    local cumulative_bytes=0

    # Run tests at each fill level
    for fill_percent in $(seq $FILL_STEP_PERCENT $FILL_STEP_PERCENT $MAX_FILL_PERCENT); do
        echo -e "\n${YELLOW}========== Fill Level: ${fill_percent}% ==========${NC}"

        # Create a unique instance name for this fill level
        local instance_name="occlum_instance_${disk_name}_${fill_percent}"

        # Step 1: Initialize fresh Occlum instance
        init_occlum_instance "$instance_name" "$disk_name"

        # Step 2: Calculate fill size
        cumulative_bytes=$(calculate_size $fill_percent)

        # Step 3: Fill disk and test performance in one occlum run (cumulative WAF)
        local result=$(fill_and_test_performance "$instance_name" "$fill_percent" "$cumulative_bytes" "$test_size_bytes")
        local throughput_str=$(echo "$result" | cut -d',' -f1)
        local waf=$(echo "$result" | cut -d',' -f2)
        local throughput_mbs=$(parse_throughput_to_mbs "$throughput_str")

        # Step 4: Save result to CSV immediately
        echo "${disk_name},${fill_percent},${throughput_mbs},${waf}" >> "$RESULT_CSV"
        echo -e "${GREEN}✓ Fill: ${fill_percent}% | Random Write Throughput: ${throughput_mbs} MB/s | WAF: ${waf}${NC}"
        echo -e "${GREEN}  Result saved to CSV${NC}"

        # Step 5: Clean up this instance to save space
        echo -e "${BLUE}Cleaning up ${instance_name}...${NC}"
        rm -rf "$instance_name"
    done

    echo -e "\n${GREEN}All results saved to ${RESULT_CSV}${NC}"
}



function generate_json_report() {
    echo -e "${YELLOW}Generating JSON report from CSV...${NC}"

    # Check if CSV file exists and has data
    if [ ! -f "${RESULT_CSV}" ]; then
        echo -e "${RED}Error: CSV file not found: ${RESULT_CSV}${NC}"
        return 1
    fi

    local line_count=$(wc -l < "${RESULT_CSV}")
    if [ "$line_count" -le 1 ]; then
        echo -e "${RED}Error: CSV file has no data (only header)${NC}"
        return 1
    fi

    echo -e "${BLUE}CSV file has $((line_count - 1)) data rows${NC}"

    # Read CSV and convert to JSON
    # Pass shell variables as command line arguments to Python
    python3 - "${RESULT_CSV}" "${RESULT_JSON}" "${DISK_SIZE_GB}" "${FILL_STEP_PERCENT}" <<'PYTHON_EOF'
import csv
import json
import sys

if len(sys.argv) != 5:
    print("Error: Missing arguments", file=sys.stderr)
    sys.exit(1)

csv_file = sys.argv[1]
json_file = sys.argv[2]
disk_size_gb = int(sys.argv[3])
fill_step_percent = int(sys.argv[4])

try:
    # Group results by disk_name
    results = {}
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            disk_name = row['disk_name']
            if disk_name not in results:
                results[disk_name] = {
                    'fill_levels': [],
                    'throughputs': [],
                    'wafs': []
                }
            results[disk_name]['fill_levels'].append(int(row['fill_percent']))
            results[disk_name]['throughputs'].append(float(row['throughput_mbs']))
            # Handle WAF, which might be "N/A"
            waf_value = row.get('waf', 'N/A')
            if waf_value == 'N/A' or waf_value == '':
                results[disk_name]['wafs'].append(None)
            else:
                try:
                    results[disk_name]['wafs'].append(float(waf_value))
                except ValueError:
                    results[disk_name]['wafs'].append(None)

    output = {
        'disk_size_gb': disk_size_gb,
        'fill_step_percent': fill_step_percent,
        'results': results
    }

    with open(json_file, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"✓ JSON report generated: {json_file}")
    print(f"  Disk types: {list(results.keys())}")
    for disk_name, data in results.items():
        print(f"  {disk_name}: {len(data['fill_levels'])} data points")

except Exception as e:
    print(f"Error generating JSON: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}JSON report generated successfully${NC}"
    else
        echo -e "${RED}Failed to generate JSON report${NC}"
        return 1
    fi
}

function print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Disk Aging Experiment Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "Disk Size: ${DISK_SIZE_GB}GB"
    echo -e "Disk Types: ${DISK_TYPES[*]}"
    echo -e "Fill Step: ${FILL_STEP_PERCENT}%"
    echo ""
    echo -e "Results saved to:"
    echo -e "  - CSV: ${RESULT_CSV}"
    echo -e "  - JSON: ${RESULT_JSON}"
    echo ""
}

function main() {
    mkdir -p "${OUTPUT_DIR}"

    # Check if fio is available
    check_fio

    # Initialize CSV with header
    echo "disk_name,fill_percent,throughput_mbs,waf" > "$RESULT_CSV"
    echo -e "${GREEN}Initialized CSV file: ${RESULT_CSV}${NC}"

    # Run aging experiment for each disk type
    for disk_name in "${DISK_TYPES[@]}"; do
        run_aging_experiment "$disk_name"
    done

    # Generate JSON report
    generate_json_report

    # Print summary
    print_summary
}

main "$@"

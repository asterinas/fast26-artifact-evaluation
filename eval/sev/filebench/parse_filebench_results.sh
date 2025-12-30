#!/bin/bash
# Parse filebench result txt files and generate JSON output
# Usage: ./parse_filebench_results.sh [output_dir] [output_json]

set -e

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
OUTPUT_DIR="${1:-${SCRIPT_DIR}/benchmark_results}"
RESULT_JSON="${2:-${OUTPUT_DIR}/result.json}"

# Workloads and disk types
WORKLOADS=("fileserver" "oltp" "varmail" "videoserver")
DISK_TYPES=("sworndisk" "cryptdisk")

function parse_single_result() {
    local txt_file=$1
    local workload=$2
    local disk_type=$3

    if [ ! -f "${txt_file}" ]; then
        echo "{\"workload\":\"${workload}\",\"disk_type\":\"${disk_type}\",\"throughput_mb_s\":null,\"ops_per_s\":null,\"latency_ms\":null,\"error\":\"file not found\"}"
        return
    fi

    # Parse IO Summary line
    # Example: "69.397: IO Summary: 410901 ops 6845.300 ops/s 622/1245 rd/wr 165.0mb/s   7.8ms/op"
    local summary_line=$(grep -i "IO Summary" "${txt_file}" 2>/dev/null | tail -1)

    if [ -z "${summary_line}" ]; then
        echo "{\"workload\":\"${workload}\",\"disk_type\":\"${disk_type}\",\"throughput_mb_s\":null,\"ops_per_s\":null,\"latency_ms\":null,\"error\":\"no IO Summary found\"}"
        return
    fi

    # Extract ops/s (e.g., 6845.300)
    local ops_per_s=$(echo "${summary_line}" | grep -oP '[\d.]+(?=\s*ops/s)' | head -1)

    # Extract throughput mb/s (e.g., 165.0)
    local throughput=$(echo "${summary_line}" | grep -oP '[\d.]+(?=mb/s)' | head -1)

    # Extract latency ms/op (e.g., 7.8)
    local latency=$(echo "${summary_line}" | grep -oP '[\d.]+(?=ms/op)' | head -1)

    # Output JSON object
    echo "{\"workload\":\"${workload}\",\"disk_type\":\"${disk_type}\",\"throughput_mb_s\":${throughput:-null},\"ops_per_s\":${ops_per_s:-null},\"latency_ms\":${latency:-null}}"
}

function main() {
    local results=()

    for workload in "${WORKLOADS[@]}"; do
        for disk_type in "${DISK_TYPES[@]}"; do
            local txt_file="${OUTPUT_DIR}/${workload}_${disk_type}_output.txt"
            local result=$(parse_single_result "${txt_file}" "${workload}" "${disk_type}")
            results+=("${result}")
        done
    done

    # Generate JSON array
    echo "[" > "${RESULT_JSON}"
    for i in "${!results[@]}"; do
        if [ $i -gt 0 ]; then
            echo "," >> "${RESULT_JSON}"
        fi
        echo "  ${results[$i]}" >> "${RESULT_JSON}"
    done
    echo "]" >> "${RESULT_JSON}"

    echo "Results saved to ${RESULT_JSON}"
    cat "${RESULT_JSON}"
}

main "$@"

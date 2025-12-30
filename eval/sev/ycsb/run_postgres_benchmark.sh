#!/usr/bin/env bash

# Script to run PostgreSQL benchmarks using go-ycsb
# Optimized for QEMU/Device-Mapper Environment compatibility

set -e

# ============================================================
# CONFIGURATION & PATHS
# ============================================================
SWORNDISK_MOUNT="/mnt/sworndisk"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

# Data roots
SWORNDISK_DATA_ROOT="${SWORNDISK_MOUNT}/ycsb"
CRYPTDISK_DATA_ROOT="${CRYPTDISK_MOUNT}/ycsb"

# Directories for pg_ctl checks
SWORNDISK_DIR="${SWORNDISK_DATA_ROOT}/postgres"
CRYPTDISK_DIR="${CRYPTDISK_DATA_ROOT}/postgres"

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
YCSB_BIN="${SCRIPT_DIR}/go-ycsb/bin/go-ycsb"
WORKLOAD_DIR="${SCRIPT_DIR}/go-ycsb/workloads"
OUTPUT_DIR="${SCRIPT_DIR}/benchmark_results"
RESULT_FILE="${OUTPUT_DIR}/postgres_results.json"

# Colors
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'
GRAY='\033[1;30m'

# Check prerequisites
if [ ! -f "${YCSB_BIN}" ]; then
    echo -e "${RED}Error: go-ycsb binary not found at ${YCSB_BIN}${NC}"
    exit 1
fi

if [ ! -d "${WORKLOAD_DIR}" ]; then
    echo -e "${RED}Error: workload directory not found at ${WORKLOAD_DIR}${NC}"
    exit 1
fi

# Workloads to test
WORKLOADS=("workloada" "workloadb" "workloade" "workloadf")
WORKLOAD_DIR="${SCRIPT_DIR}/workloads"
RECORD_COUNT=100000
OPERATION_COUNT=100000

# Database Connection Params
PG_USER="root"
PG_PASSWORD="root"
PG_DB="test"
PG_HOST="127.0.0.1" 
SWORNDISK_PORT=5433
CRYPTDISK_PORT=5434

# ============================================================
# HELPER FUNCTIONS
# ============================================================

check_instance_ready() {
    local name=$1
    local port=$2
    local data_dir=$3

    # 1. Check process
    if [ ! -f "${data_dir}/postmaster.pid" ]; then
        return 1
    fi
    local pid=$(head -1 "${data_dir}/postmaster.pid")
    if ! ps -p $pid > /dev/null 2>&1; then
        return 1
    fi

    # 2. Check TCP connectivity
    if ! PGPASSWORD=${PG_PASSWORD} psql -h ${PG_HOST} -p ${port} -U ${PG_USER} -d ${PG_DB} -c '\q' >/dev/null 2>&1; then
        echo -e "${RED}Error: Cannot connect to ${name} via TCP port ${port}.${NC}"
        return 1
    fi

    return 0
}

cleanup_ycsb_table() {
    local port=$1
    echo -e "${YELLOW}   -> Dropping old 'usertable'...${NC}"
    PGPASSWORD=${PG_PASSWORD} psql -h ${PG_HOST} -p ${port} -U ${PG_USER} -d ${PG_DB} -c "DROP TABLE IF EXISTS usertable;" >/dev/null 2>&1
}

run_benchmark() {
    local workload=$1
    local name=$2
    local port=$3

    echo -e "${YELLOW}----------------------------------------${NC}"
    echo -e "${YELLOW}Testing: ${name} @ Port ${port} - ${workload}${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"

    # 1. Clean old data
    echo -ne "${GRAY}   -> Cleaning old tables... ${NC}"
    if cleanup_ycsb_table ${port}; then
        echo -e "${GREEN}Done.${NC}"
    else
        echo -e "${RED}Failed. Skipping.${NC}"
        return 1
    fi

    # 2. Load Phase
    echo -e "${GREEN}   [1/2] Loading data...${NC}"
    "${YCSB_BIN}" load pg -P "${WORKLOAD_DIR}/${workload}" \
        -p pg.host="${PG_HOST}" \
        -p pg.port="${port}" \
        -p pg.user="${PG_USER}" \
        -p pg.password="${PG_PASSWORD}" \
        -p pg.db="${PG_DB}" \
        -p recordcount=${RECORD_COUNT} \
        -p operationcount=${OPERATION_COUNT} \
        -p pg.sslmode=disable \
        > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}   Load failed! Skipping run.${NC}"
        return 1
    fi

    # 3. Run Phase
    echo -e "${GREEN}   [2/2] Running benchmark...${NC}"
    local output_file=$(mktemp)
    
    "${YCSB_BIN}" run pg -P "${WORKLOAD_DIR}/${workload}" \
        -p pg.host="${PG_HOST}" \
        -p pg.port="${port}" \
        -p pg.user="${PG_USER}" \
        -p pg.password="${PG_PASSWORD}" \
        -p pg.db="${PG_DB}" \
        -p recordcount=${RECORD_COUNT} \
        -p operationcount=${OPERATION_COUNT} \
        -p pg.sslmode=disable \
        2>&1 | tee "${output_file}"

    # 4. Parse Results (CRITICAL FIX HERE)
    # Use tail -n 1 to ensure only the last line is captured (the TOTAL line after "Run finished")
    # Avoid capturing intermediate progress reports (Takes 10s, Takes 20s...)
    local throughput=$(grep -i "TOTAL" "${output_file}" | tail -n 1 | sed -nE 's/.*(OPS|Ops\/Sec):\s*([0-9.]+).*/\2/p')

    # Fallback if empty
    if [ -z "$throughput" ]; then
        throughput="0"
    fi

    echo -e "${BLUE}   Result: ${throughput} Ops/Sec${NC}"
    echo ""

    # 5. Write JSON
    if [ "$FIRST_RESULT" = true ]; then
        FIRST_RESULT=false
    else
        echo "    ," >> "${RESULT_FILE}"
    fi

    # Use echo for writing to avoid cat compatibility issues
    echo "    {" >> "${RESULT_FILE}"
    echo "      \"workload\": \"${workload}\"," >> "${RESULT_FILE}"
    echo "      \"filesystem\": \"${name}\"," >> "${RESULT_FILE}"
    echo "      \"port\": ${port}," >> "${RESULT_FILE}"
    echo "      \"throughput_ops_sec\": ${throughput}" >> "${RESULT_FILE}"
    echo "    }" >> "${RESULT_FILE}"

    rm -f "${output_file}"
}

# ============================================================
# MAIN EXECUTION
# ============================================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}PostgreSQL Benchmark - go-ycsb${NC}"
echo -e "${BLUE}========================================${NC}"

# Check Instances
SWORNDISK_READY=false
CRYPTDISK_READY=false

if check_instance_ready "CryptDisk" ${CRYPTDISK_PORT} "${CRYPTDISK_DIR}"; then
    CRYPTDISK_READY=true
    echo -e "${GREEN}✓ CryptDisk Ready (Port ${CRYPTDISK_PORT})${NC}"
else
    echo -e "${YELLOW}⚠ CryptDisk NOT ready (Skipping)${NC}"
fi

if check_instance_ready "SwornDisk" ${SWORNDISK_PORT} "${SWORNDISK_DIR}"; then
    SWORNDISK_READY=true
    echo -e "${GREEN}✓ SwornDisk Ready (Port ${SWORNDISK_PORT})${NC}"
else
    echo -e "${YELLOW}⚠ SwornDisk NOT ready (Skipping)${NC}"
fi

if [ "$SWORNDISK_READY" = false ] && [ "$CRYPTDISK_READY" = false ]; then
    echo ""
    echo -e "${RED}No running instances found.${NC}"
    exit 1
fi

# Initialize JSON
mkdir -p "${OUTPUT_DIR}"
echo "{" > "${RESULT_FILE}"
echo "  \"benchmark\": \"PostgreSQL YCSB\"," >> "${RESULT_FILE}"
echo "  \"timestamp\": \"$(date)\"," >> "${RESULT_FILE}"
echo "  \"results\": [" >> "${RESULT_FILE}"

FIRST_RESULT=true

# Loop through workloads
echo ""
for workload in "${WORKLOADS[@]}"; do
    if [ "$SWORNDISK_READY" = true ]; then
        run_benchmark "${workload}" "SwornDisk" ${SWORNDISK_PORT}
    fi
    
    if [ "$CRYPTDISK_READY" = true ]; then
        run_benchmark "${workload}" "CryptDisk" ${CRYPTDISK_PORT}
    fi
done

# Close JSON
echo "" >> "${RESULT_FILE}"
echo "  ]" >> "${RESULT_FILE}"
echo "}" >> "${RESULT_FILE}"

echo -e "${GREEN}Benchmark complete.${NC}"
echo -e "Results saved to: ${BLUE}${RESULT_FILE}${NC}"

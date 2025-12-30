#!/bin/bash

# Script to initialize and manage PostgreSQL instances on SwornDisk/CryptDisk
# Optimized for Minimal QEMU/Device-Mapper Development Environment

set -e

# ============================================================
# DEVICE & FILESYSTEM PATHS
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"

SWORNDISK_MOUNT="/mnt/sworndisk"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

# Data roots on each mounted filesystem
SWORNDISK_DATA_ROOT="${SWORNDISK_MOUNT}/ycsb"
CRYPTDISK_DATA_ROOT="${CRYPTDISK_MOUNT}/ycsb"

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
MOUNT_SCRIPT="${SCRIPT_DIR}/../mount_filesystems.sh"
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'

# Configuration
SWORNDISK_DIR="${SWORNDISK_DATA_ROOT}/postgres"
CRYPTDISK_DIR="${CRYPTDISK_DATA_ROOT}/postgres"
POSTGRES_USER="postgres"

# Port configuration
SWORNDISK_PORT=5433
CRYPTDISK_PORT=5434

# Detect PostgreSQL version (Fixed for minimal environments without grep -P)
# Added || true to prevent set -e from exiting if psql is missing during check
POSTGRES_VERSION=$(psql --version 2>/dev/null | awk '{print $3}' | awk -F. '{print $1}' || true)

if [ -z "$POSTGRES_VERSION" ]; then
    echo -e "${RED}Error: PostgreSQL is not installed (psql not found)${NC}"
    exit 1
fi

check_mount_point() {
    local mountpoint=$1
    if ! mountpoint -q "$mountpoint"; then return 1; fi
    return 0
}

ensure_filesystems() {
    local ready=true
    if ! check_mount_point "${SWORNDISK_MOUNT}"; then ready=false; fi
    if ! check_mount_point "${CRYPTDISK_MOUNT}"; then ready=false; fi

    if [ "$ready" = false ]; then
        echo -e "${RED}Error: Filesystems not mounted at ${SWORNDISK_MOUNT} and/or ${CRYPTDISK_MOUNT}${NC}"
        echo -e "${YELLOW}Please mount them first (e.g., run ${MOUNT_SCRIPT})${NC}"
        exit 1
    fi
}

reset_sworndisk() {
    if [ -x "${RESET_SWORN_SCRIPT}" ]; then
        echo -e "${YELLOW}Resetting sworndisk...${NC}"
        bash "${RESET_SWORN_SCRIPT}" || echo -e "${RED}Failed to reset sworndisk${NC}"
    else
        echo -e "${YELLOW}Reset script not found at ${RESET_SWORN_SCRIPT}${NC}"
    fi
}

instance_running() {
    local data_dir=$1
    if [ -f "${data_dir}/postmaster.pid" ]; then
        local pid
        pid=$(head -1 "${data_dir}/postmaster.pid")
        if ps -p $pid > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

ensure_writable_dir() {
    local dir=$1
    mkdir -p "${dir}" 2>/dev/null || sudo mkdir -p "${dir}"
    
    if [ "$EUID" -eq 0 ]; then
        chown -R ${POSTGRES_USER}:${POSTGRES_USER} "${dir}"
    else
        sudo chown -R ${POSTGRES_USER}:${POSTGRES_USER} "${dir}"
    fi
}

# Pre-checks
ensure_filesystems
mkdir -p "${SWORNDISK_DATA_ROOT}" "${CRYPTDISK_DATA_ROOT}"

init_instance() {
    local name=$1
    local data_dir=$2
    local port=$3
    local instance_cmd=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    echo -e "${YELLOW}Initializing PostgreSQL for ${name}${NC}"

    # 1. Create directory and set ownership BEFORE initdb
    echo -e "${YELLOW}[1/4] Preparing data directory...${NC}"
    ensure_writable_dir "${data_dir}"

    if [ -f "${data_dir}/PG_VERSION" ]; then
        echo -e "${YELLOW}Already initialized.${NC}"
        return 0
    fi

    # 2. Initialize database cluster
    echo -e "${YELLOW}[2/4] Initializing database cluster...${NC}"
    # Use LC_ALL=C to avoid locale issues in minimal VMs
    if [ "$EUID" -eq 0 ]; then
        sudo -u ${POSTGRES_USER} LC_ALL=C /usr/lib/postgresql/${POSTGRES_VERSION}/bin/initdb -D "${data_dir}"
    else
        LC_ALL=C /usr/lib/postgresql/${POSTGRES_VERSION}/bin/initdb -D "${data_dir}"
    fi
    echo -e "${GREEN}✓ Initialized${NC}"

    # 3. Configure PostgreSQL
    echo -e "${YELLOW}[3/4] Configuring PostgreSQL...${NC}"
    sed -i "s/#port = 5432/port = ${port}/" "${data_dir}/postgresql.conf"
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "${data_dir}/postgresql.conf"
    
    # Custom socket dir to avoid /var/run permissions issues
    mkdir -p "${data_dir}/run"
    chown ${POSTGRES_USER}:${POSTGRES_USER} "${data_dir}/run"
    sed -i "s|#unix_socket_directories = '/var/run/postgresql'|unix_socket_directories = '${data_dir}/run'|" "${data_dir}/postgresql.conf"

    # [CRITICAL] Allow TCP connections without password (trust) for testing
    echo "" >> "${data_dir}/pg_hba.conf"
    echo "# ALLOW ALL REMOTE ACCESS FOR TESTING" >> "${data_dir}/pg_hba.conf"
    echo "host    all             all             0.0.0.0/0               trust" >> "${data_dir}/pg_hba.conf"
    echo "host    all             all             ::/0                    trust" >> "${data_dir}/pg_hba.conf"

    echo -e "${GREEN}✓ Configuration updated (Trust Auth Enabled)${NC}"

    # 4. Set permissions
    chmod 700 "${data_dir}"
    echo -e "${GREEN}✓ Permissions set${NC}"
}

start_instance() {
    local name=$1
    local data_dir=$2
    local port=$3
    local instance_cmd=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    echo -e "${YELLOW}Starting PostgreSQL instance: ${name}${NC}"
    echo "Data Directory: ${data_dir}"
    echo "Port: ${port}"

    if [ ! -f "${data_dir}/PG_VERSION" ]; then
        echo -e "${RED}Error: PostgreSQL instance not initialized${NC}"
        echo "Run: $0 init ${instance_cmd}"
        return 1
    fi

    # Check if already running
    if [ -f "${data_dir}/postmaster.pid" ]; then
        local pid=$(head -1 "${data_dir}/postmaster.pid")
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${GREEN}PostgreSQL is running (PID: ${pid})${NC}"
            return 0
        else
            echo -e "${YELLOW}Removing stale PID file...${NC}"
            rm -f "${data_dir}/postmaster.pid"
        fi
    fi

    # Create socket directory
    mkdir -p "${data_dir}/run"
    if [ "$EUID" -eq 0 ]; then
        chown ${POSTGRES_USER}:${POSTGRES_USER} "${data_dir}/run"
    fi

    # Start PostgreSQL
    local START_CMD="/usr/lib/postgresql/${POSTGRES_VERSION}/bin/pg_ctl -D ${data_dir} -l ${data_dir}/postgresql.log start"
    
    if [ "$EUID" -eq 0 ]; then
        sudo -u ${POSTGRES_USER} bash -c "$START_CMD"
    else
        eval "$START_CMD"
    fi

    sleep 2

    # Check if started successfully
    if [ -f "${data_dir}/postmaster.pid" ]; then
        local pid=$(head -1 "${data_dir}/postmaster.pid")
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${GREEN}✓ PostgreSQL started successfully (PID: ${pid})${NC}"
            echo "Socket: ${data_dir}/run"
            return 0
        fi
    fi

    echo -e "${RED}Failed to start PostgreSQL${NC}"
    echo "Check log: ${data_dir}/postgresql.log"
    return 1
}

stop_instance() {
    local name=$1
    local data_dir=$2

    echo -e "${YELLOW}Stopping PostgreSQL instance: ${name}${NC}"

    if [ ! -f "${data_dir}/postmaster.pid" ]; then
        echo -e "${YELLOW}Instance is not running${NC}"
        return 0
    fi

    local STOP_CMD="/usr/lib/postgresql/${POSTGRES_VERSION}/bin/pg_ctl -D ${data_dir} stop"

    if [ "$EUID" -eq 0 ]; then
        sudo -u ${POSTGRES_USER} bash -c "$STOP_CMD"
    else
        eval "$STOP_CMD"
    fi

    echo -e "${GREEN}✓ PostgreSQL stopped${NC}"
}

status_instance() {
    local name=$1
    local data_dir=$2
    local port=$3

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}PostgreSQL Instance: ${name}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Data Directory: ${data_dir}"
    echo "Port: ${port}"

    if [ ! -f "${data_dir}/PG_VERSION" ]; then
        echo -e "Status: ${RED}Not initialized${NC}"
        return
    fi

    if [ -f "${data_dir}/postmaster.pid" ]; then
        local pid=$(head -1 "${data_dir}/postmaster.pid")
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "Status: ${GREEN}Running (PID: ${pid})${NC}"
        else
            echo -e "Status: ${RED}Stopped (stale PID file)${NC}"
        fi
    else
        echo -e "Status: ${RED}Stopped${NC}"
    fi
    echo ""
}

init_ycsb_db() {
    local name=$1
    local data_dir=$2
    local port=$3

    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Initializing YCSB Database: ${name}${NC}"
    echo -e "${YELLOW}========================================${NC}"

    if ! instance_running "${data_dir}"; then
        echo -e "${RED}Error: PostgreSQL instance is not running. Start it first.${NC}"
        return 1
    fi

    echo "Creating YCSB database and user..."
    
    # Using Unix Socket explicitly to avoid TCP Auth issues during setup
    # Host is set to the custom socket directory
    local SOCKET_DIR="${data_dir}/run"
    
    local SQL_CMDS="
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = 'root') THEN
            CREATE USER root WITH PASSWORD 'root';
        END IF;
    END
    \$\$;
    SELECT 'CREATE DATABASE test OWNER root' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'test')\gexec
    GRANT ALL PRIVILEGES ON DATABASE test TO root;
    "

    if [ "$EUID" -eq 0 ]; then
        echo "$SQL_CMDS" | sudo -u ${POSTGRES_USER} psql -h "${SOCKET_DIR}" -p ${port} -d postgres -f - > /dev/null 2>&1
    else
        echo "$SQL_CMDS" | psql -h "${SOCKET_DIR}" -p ${port} -d postgres -f - > /dev/null 2>&1
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ YCSB database initialized successfully${NC}"
        echo "  URL: postgresql://root:root@localhost:${port}/test"
    else
        echo -e "${RED}Failed to initialize YCSB database${NC}"
        echo "Check PostgreSQL log: ${data_dir}/postgresql.log"
        return 1
    fi
}

clean_instance() {
    local name=$1
    local data_dir=$2

    echo -e "${RED}========================================${NC}"
    echo -e "${RED}WARNING: Clean Instance${NC}"
    echo -e "${RED}========================================${NC}"
    echo "This will DELETE all data in: ${data_dir}"
    read -p "Are you sure? Type 'yes' to confirm: " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        return
    fi

    if [ -f "${data_dir}/postmaster.pid" ]; then
        stop_instance "$name" "$data_dir"
        sleep 2
    fi

    echo "Removing data directory..."
    rm -rf "${data_dir}"
    echo -e "${GREEN}✓ Instance cleaned${NC}"
}

# Main command handler
case "${1:-}" in
    init)
        case "${2:-}" in
            sworndisk) init_instance "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT" ;;
            cryptdisk) init_instance "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT" ;;
            *) echo "Usage: $0 init [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    start)
        case "${2:-}" in
            sworndisk) start_instance "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT" ;;
            cryptdisk) start_instance "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT" ;;
            *) echo "Usage: $0 start [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    stop)
        case "${2:-}" in
            sworndisk) stop_instance "SwornDisk" "$SWORNDISK_DIR" ;;
            cryptdisk) stop_instance "CryptDisk" "$CRYPTDISK_DIR" ;;
            *) echo "Usage: $0 stop [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    restart)
        case "${2:-}" in
            sworndisk) 
                stop_instance "SwornDisk" "$SWORNDISK_DIR"
                sleep 2
                start_instance "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT"
                ;;
            cryptdisk) 
                stop_instance "CryptDisk" "$CRYPTDISK_DIR"
                sleep 2
                start_instance "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT"
                ;;
            *) echo "Usage: $0 restart [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    status)
        case "${2:-}" in
            sworndisk) status_instance "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT" ;;
            cryptdisk) status_instance "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT" ;;
            all|"") 
                status_instance "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT"
                status_instance "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT"
                ;;
        esac
        ;;
    init-ycsb)
        case "${2:-}" in
            sworndisk) init_ycsb_db "SwornDisk" "$SWORNDISK_DIR" "$SWORNDISK_PORT" ;;
            cryptdisk) init_ycsb_db "CryptDisk" "$CRYPTDISK_DIR" "$CRYPTDISK_PORT" ;;
            *) echo "Usage: $0 init-ycsb [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    clean)
        case "${2:-}" in
            sworndisk) clean_instance "SwornDisk" "$SWORNDISK_DIR" ;;
            cryptdisk) clean_instance "CryptDisk" "$CRYPTDISK_DIR" ;;
            *) echo "Usage: $0 clean [sworndisk|cryptdisk]"; exit 1 ;;
        esac
        ;;
    *)
        echo "PostgreSQL Instance Manager for SwornDisk Env"
        echo "Usage: $0 <command> <instance>"
        echo "Commands: init, start, stop, restart, status, init-ycsb, clean"
        exit 1
        ;;
esac
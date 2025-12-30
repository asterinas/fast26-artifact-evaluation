#!/bin/bash

set -e

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}cpp-ycsb full environment setup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 1: Install build tools
echo -e "${YELLOW}[1/4] Checking build tools...${NC}"
if ! command -v cmake &> /dev/null || ! command -v g++ &> /dev/null; then
    echo -e "${YELLOW}Installing build tools...${NC}"
    sudo apt update
    sudo apt install -y build-essential cmake pkg-config
    echo -e "${GREEN}[OK] Build tools installed${NC}"
else
    echo -e "${GREEN}[OK] Build tools already present${NC}"
fi
echo ""

# Step 2: Install compression libraries (required by RocksDB)
echo -e "${YELLOW}[2/4] Checking compression libraries...${NC}"
MISSING_LIBS=0

for lib in libsnappy-dev liblz4-dev libzstd-dev libbz2-dev zlib1g-dev; do
    if ! dpkg -l | grep -q "^ii  $lib"; then
        MISSING_LIBS=1
        break
    fi
done

if [ $MISSING_LIBS -eq 1 ]; then
    echo -e "${YELLOW}Installing compression libraries...${NC}"
    sudo apt install -y \
        libsnappy-dev \
        liblz4-dev \
        libzstd-dev \
        libbz2-dev \
        zlib1g-dev \
        libgflags-dev
    echo -e "${GREEN}[OK] Compression libraries installed${NC}"
else
    echo -e "${GREEN}[OK] Compression libraries already present${NC}"
fi
echo ""

# Step 3: Install RocksDB
echo -e "${YELLOW}[3/4] Checking RocksDB...${NC}"
if ! ldconfig -p | grep -q librocksdb; then
    echo -e "${YELLOW}RocksDB not found, installing...${NC}"
    echo ""
    echo "Choose installation method:"
    echo "  1) Install from package manager (recommended, fast)"
    echo "  2) Build from source (latest version, takes 10-15 minutes)"
    echo ""
    read -p "Select (1 or 2, default 1): " choice
    choice=${choice:-1}

    if [ "$choice" == "1" ]; then
        echo -e "${YELLOW}Installing RocksDB from package manager...${NC}"
        sudo apt update
        sudo apt install -y librocksdb-dev
    else
        echo -e "${YELLOW}Building RocksDB from source...${NC}"
        ROCKSDB_DIR="/tmp/rocksdb-build-$$"
        git clone https://github.com/facebook/rocksdb.git "$ROCKSDB_DIR"
        cd "$ROCKSDB_DIR"
        make shared_lib -j$(nproc)
        sudo make install-shared
        cd - > /dev/null
        rm -rf "$ROCKSDB_DIR"
    fi

    sudo ldconfig
    echo -e "${GREEN}[OK] RocksDB installed${NC}"
else
    echo -e "${GREEN}[OK] RocksDB already present${NC}"
fi

# Verify RocksDB installation
if ldconfig -p | grep -q librocksdb; then
    echo -e "${GREEN}  RocksDB library path:${NC}"
    ldconfig -p | grep rocksdb | head -3
else
    echo -e "${RED}[FAIL] RocksDB installation failed${NC}"
    exit 1
fi
echo ""

# Step 4: Build cpp-ycsb
echo -e "${YELLOW}[4/4] Building cpp-ycsb...${NC}"
cd "${SCRIPT_DIR}"

# Clean previous build
if [ -d "build" ]; then
    echo -e "${YELLOW}Cleaning previous build artifacts...${NC}"
    rm -rf build
fi

mkdir -p build bin

# Run CMake
cd build
echo -e "${YELLOW}Running CMake...${NC}"
if cmake .. -DCMAKE_BUILD_TYPE=Release; then
    echo -e "${GREEN}[OK] CMake configure succeeded${NC}"
else
    echo -e "${RED}[FAIL] CMake configure failed${NC}"
    exit 1
fi

# Compile
echo ""
echo -e "${YELLOW}Compiling...${NC}"
if make -j$(nproc); then
    echo -e "${GREEN}[OK] Build succeeded${NC}"
else
    echo -e "${RED}[FAIL] Build failed${NC}"
    exit 1
fi

cd ..

# Verify binary
if [ -f "bin/ycsb" ]; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Environment setup complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Binary: ${GREEN}${SCRIPT_DIR}/bin/ycsb${NC}"
    echo ""
else
    echo -e "${RED}[FAIL] Build failed, binary not found${NC}"
    exit 1
fi

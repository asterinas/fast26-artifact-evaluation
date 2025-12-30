#!/bin/bash
set -e

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

echo -e "${BLUE}Start downloading and building filebench from source.${NC}"

# Install dependencies first
if ! command -v bison &> /dev/null || ! command -v flex &> /dev/null; then
    echo -e "${YELLOW}Installing dependencies...${NC}"
    "${SCRIPT_DIR}/preinstall_deps.sh"
fi

# Download release tarball
VERSION="1.5-alpha3"
TARBALL="filebench-${VERSION}.tar.gz"

cd "${SCRIPT_DIR}"

if [ -f "${TARBALL}" ]; then
    echo -e "${YELLOW}Tarball already exists, skipping download${NC}"
else
    echo -e "${BLUE}Downloading filebench ${VERSION}...${NC}"
    wget https://github.com/filebench/filebench/releases/download/${VERSION}/${TARBALL}
fi

# Extract tarball
echo -e "${BLUE}Extracting tarball...${NC}"
rm -rf filebench && mkdir filebench
tar -zxf ${TARBALL} -C filebench --strip-components 1

cd filebench

# Configure and build (no patches needed for Linux)
echo -e "${BLUE}Configuring filebench...${NC}"
./configure

echo -e "${BLUE}Building filebench with $(nproc) cores...${NC}"
make -j$(nproc)

echo -e "${BLUE}Installing filebench to /usr/local/bin...${NC}"
sudo make install

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Filebench built and installed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Filebench binary: $(which filebench)${NC}"
echo -e "${GREEN}Version: $(filebench -h 2>&1 | head -1 || echo 'Filebench 1.5-alpha3')${NC}"

cd "${SCRIPT_DIR}"

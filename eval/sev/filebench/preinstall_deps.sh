#!/bin/bash
set -e

BLUE='\033[1;34m'
NC='\033[0m'
echo -e "${BLUE}Start installing filebench dependencies.${NC}"

DEPS="bison flex libtool automake"

OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
if [ "$OS" == "\"Ubuntu\"" ]; then
  sudo apt-get update -y && sudo apt-get install -y ${DEPS}
else
  echo "Unsupported OS: $OS"
  echo "Please manually install: ${DEPS}"
  exit 1
fi

echo -e "${BLUE}Finish installing dependencies.${NC}"

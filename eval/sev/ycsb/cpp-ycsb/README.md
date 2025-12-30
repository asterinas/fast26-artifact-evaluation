# cpp-ycsb (RocksDB-only YCSB in C++)

Small C++ port of YCSB focused on RocksDB. Use it to load and run standard YCSB workloads with minimal setup.

## Quick start

```bash
./setup.sh            # install deps and build

# load and run workload A against a temp db path
./bin/ycsb load -P ../workloads/workloada -db /tmp/cpp-ycsb-demo
./bin/ycsb run  -P ../workloads/workloada -db /tmp/cpp-ycsb-demo
```

## Requirements

- Ubuntu/Debian with build-essential, cmake, pkg-config
- RocksDB plus compression libs (snappy, lz4, zstd, bz2, zlib). `./setup.sh` installs everything.

## Workloads

Preset files live in `workloads/`:
- workloada: 50% read, 50% update
- workloadb: 95% read, 5% update
- workloade: 95% scan, 5% insert
- workloadf: 50% read-modify-write, 5% update

Adjust recordcount/operationcount inside each file to scale load.

## Build (if you want manual control)

```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```
Binary lands at `bin/ycsb` in the project root.

## Troubleshooting (fast answers)

- RocksDB not found: rerun `./setup.sh` or `sudo apt install -y librocksdb-dev && sudo ldconfig`.
- Missing compression libs or linker errors: rerun `./setup.sh`.
- Clean rebuild: `rm -rf build bin && ./setup.sh`.

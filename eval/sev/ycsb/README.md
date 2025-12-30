# YCSB Benchmarks (SwornDisk/CryptDisk)

One place to prep env, build tools, and run YCSB on BoltDB, SQLite, PostgreSQL, and RocksDB.

## 0. Setup

**Note:** If you are using the machine we priovided, you can skip this step.

```bash
# from the repo root
cd sev/ycsb
./setup.sh
# if you open a fresh shell afterwards
source ~/.bashrc
```
What it does: installs Go/PostgreSQL/SQLite, sets Go env, clones go-ycsb, builds go-ycsb and cpp-ycsb.

## Block devices and filesystems (required before benches)

```bash
# wipe and re-create dm-integrity + dm-crypt and sworndisk
../reset_crypt.sh
../reset_sworn.sh

# format and mount both as ext4
../mount_filesystems.sh
```

Expected state:
- Mapped devices: /dev/mapper/test-sworndisk, /dev/mapper/test-crypt
- Mount points: /mnt/sworndisk, /mnt/cryptdisk



## 1. Embedded DB benchmarks (BoltDB / SQLite / RocksDB)

```bash
./run_boltdb_benchmark.sh
./run_sqlite_benchmark.sh
./run_rocksdb_benchmark.sh
```

Each runs workloads A/B/E/F and writes results beside the scripts:
- BoltDB → boltdb_results.json
- SQLite → sqlite_results.json
- RocksDB → rocksdb_results.json

## 2. PostgreSQL Benchmark

PostgreSQL requires a running server instance, making its setup more complex than embedded databases. We use `configure_postgres.sh` to manage the lifecycle.

We strongly recommend running the PostgreSQL benchmark last, as it requires manual configuration. Once completed, you can power off the virtual machine directly without needing to manually stop the PostgreSQL server.

**Note:** The benchmark scripts for BoltDB, SQLite, and RocksDB automatically unmount filesystems upon completion. Therefore, you must reset the device and remount the filesystems before configuring PostgreSQL.

### Step 2.1: Preparation & Initialization
Execute the following sequence to ensure a clean state, mount filesystems, and prepare the database instances.

```bash
# 1. Reset SwornDisk and mount filesystems
# (Required because previous benchmarks unmount them)
../reset_sworn.sh
../reset_crypt.sh
../mount_filesystems.sh

# 2. Initialize data directories
./configure_postgres.sh init sworndisk
./configure_postgres.sh init cryptdisk

# 3. Start instances
./configure_postgres.sh start sworndisk
./configure_postgres.sh start cryptdisk

# 4. Create YCSB database (db=test, user=root)
./configure_postgres.sh init-ycsb sworndisk
./configure_postgres.sh init-ycsb cryptdisk

```

### Step 2.2: Execution
Once the instances are running and configured, run the full benchmark suite (Workloads A/B/E/F).
```Bash
./run_postgres_benchmark.sh
```
Output File: postgres_results.json


### Step 3: Generate Plot
Run the plotting script to visualize the benchmark results. The final chart will be generated at `result.png`.

```bash
python3 plot_result.py
```

## Scripts and binaries

- [setup.sh](setup.sh): env deps + build go-ycsb/cpp-ycsb
- [configure_postgres.sh](configure_postgres.sh): init/start/stop/status/init-ycsb for the two Postgres instances
- Bench runners: [run_boltdb_benchmark.sh](run_boltdb_benchmark.sh), [run_sqlite_benchmark.sh](run_sqlite_benchmark.sh), [run_postgres_benchmark.sh](run_postgres_benchmark.sh), [run_rocksdb_benchmark.sh](run_rocksdb_benchmark.sh)
- Binaries after setup: go-ycsb/bin/go-ycsb, cpp-ycsb/bin/ycsb
- More detail: [POSTGRES_README.md](POSTGRES_README.md), [cpp-ycsb/README.md](cpp-ycsb/README.md)

## Quick fixes

- Go env not active: source ~/.bashrc
- go-ycsb binary missing: rerun setup.sh or run make inside go-ycsb
- PostgreSQL not running: ./configure_postgres.sh start sworndisk (or cryptdisk)
- RocksDB deps/cpp-ycsb: cd cpp-ycsb && ./setup.sh


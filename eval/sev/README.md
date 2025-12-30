# Evaluation on SEV

This repository contains the evaluation scripts and benchmarks for SEV, comparing **MlsDisk** against a baseline **CryptDisk** (dm-crypt + dm-integrity).

## Overview

The evaluation covers four main categories:
1.  **FIO**: Micro-benchmarks for raw block device performance.
2.  **Trace-driven**: Replay of real-world traces (MSR Cambridge) on block devices.
3.  **Filebench**: Filesystem-level benchmarks (File Server, Mail Server, OLTP, Video Server).
4.  **YCSB**: Application-level benchmarks using embedded (BoltDB, SQLite, RocksDB) and server-based (PostgreSQL) databases.

## Environment Setup

Prepare a virtual machine and build the rust-for-linux kernel and dm-sworndisk.ko followed by the instructions in the [README](../../linux/README.md).

In the virtual machine we provided, the benchmarks rely on two specific block devices:
*   **MlsDisk**: Backed by `/dev/vda`, mapped to `/dev/mapper/test-sworndisk`.
*   **CryptDisk**: Backed by `/dev/vdb`, mapped to `/dev/mapper/test-crypt`.

### Helper Scripts

The root directory contains several utility scripts to manage the environment:

*   `reset_sworn.sh`: Re-initializes the MlsDisk device (reloads kernel module, resets device mapper).
*   `reset_crypt.sh`: Re-initializes the CryptDisk device (dm-crypt + dm-integrity).
*   `mount_filesystems.sh`: Formats (ext4) and mounts both devices to `/mnt/sworndisk` and `/mnt/cryptdisk`.
*   `umount_filesystems.sh`: Unmounts the filesystems.

**Note:** Most benchmark scripts will handle device initialization automatically, but these scripts are useful for manual testing or debugging.

## 1. FIO Benchmark

Tests raw block device performance (Sequential/Random Read/Write).

```bash
cd fio
./run.sh
```
*   **Results**: Saved in `fio/benchmark_results/`.
*   **Plotting**: `python3 plot_result.py` (generates figures in the same folder).

## 2. Trace-driven Benchmark

Replays MSR Cambridge traces (hm, mds, prn, wdev, web) on raw block devices.

**Prerequisite**: Trace files must be prepared. If running on the provided test machine, they are already available in `msr-test/`. Otherwise, download from [SNIA IOTTA](https://iotta.snia.org/traces/block-io/388).

```bash
cd trace
./run.sh
```
*   **Results**: Saved in `trace/benchmark_results/`.
*   **Plotting**: `python3 plot_result.py`.

## 3. Filebench

Tests filesystem performance using standard workloads (fileserver, varmail, oltp, videoserver).

**Prerequisite**: Disabling ASLR is recommended for Filebench stability.
```bash
echo 0 | sudo tee /proc/sys/kernel/randomize_va_space
```

```bash
cd filebench
./run.sh
```
*   **Results**: Saved in `filebench/benchmark_results/`.
*   **Plotting**: `python3 plot_result.py`.

## 4. YCSB Benchmark

Tests database performance. This is the most complex benchmark suite involving multiple databases.

Please refer to [ycsb/README.md](ycsb/README.md) for detailed instructions.

*   **Results**: Saved in `ycsb/benchmark_results/`.
*   **Plotting**: `python3 plot_result.py`.

## Result Analysis

To generate plots for all benchmarks after running them:

```bash
# FIO
cd fio && python3 plot_result.py && cd ..

# Trace
cd trace && python3 plot_result.py && cd ..

# Filebench
cd filebench && python3 plot_result.py && cd ..

# YCSB
cd ycsb && python3 plot_result.py && cd ..
```

paper figure mapping:
- FIO → Figure 10 (c, d)
- Trace → Figure 11 (b)
- Filebench → Figure 12 (b)
- YCSB → Figure 13 (a, b, c, d)

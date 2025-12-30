# Trace Replay Benchmark for SEV

This directory contains scripts to benchmark SwornDisk and CryptDisk using MSR Cambridge traces with direct block device access.

## Overview

The benchmark replays real-world I/O traces from Microsoft Research Cambridge datasets directly on block devices:
- **SwornDisk**: `/dev/mapper/test-sworndisk`
- **CryptDisk**: `/dev/mapper/test-crypt` (dm-crypt + dm-integrity)

The tests run directly on block devices without filesystem overhead, providing more accurate low-level I/O performance measurements for real-world workload patterns.

## Trace Datasets

Five trace datasets are tested (0-variants):
- **hm_0**: Home directories
- **mds_0**: Media server
- **prn_0**: Print server
- **wdev_0**: Web development
- **web_0**: Web server

Each trace contains real I/O operations (reads/writes) with timestamps, offsets, and sizes.

## Prerequisites

1. Install build tools:
   ```bash
   sudo apt install -y build-essential g++
   ```

2. Install Python dependencies for plotting:
   ```bash
   sudo apt install -y python3-matplotlib python3-numpy
   ```

3. Ensure block devices are set up:
   - SwornDisk device mapper: `/dev/mapper/test-sworndisk`
   - CryptDisk device mapper: `/dev/mapper/test-crypt`

   Use the provided reset scripts to initialize devices:
   ```bash
   # Initialize SwornDisk
   ../reset_sworn.sh

   # Initialize CryptDisk (if needed)
   ../reset_crypt.sh
   ```

4. **Root/sudo access required**: Direct block device access requires root permissions

5. Trace data files:
   You need to place the `msr-test` directory containing `*.csv` trace files in this directory.

## How It Works

### Trace Program (trace.cpp)

The C++ program:
1. **Phase 1**: Parses the trace file and collects all I/O operations
2. **Phase 2**: Warmup - for SwornDisk, pre-writes blocks that will be read but never written (avoids reading uninitialized data)
3. **Phase 3**: Replays the trace, performing reads/writes as specified
4. **Output**: Reports bandwidth (MiB/s)

### Test Script (run_trace_benchmark.sh)

The script:
1. Checks for compiler and trace data
2. Compiles the trace program
3. For each disk type and trace:
   - Syncs the block device
   - Runs the trace program on the block device
   - Parses bandwidth results
   - Syncs the device again
   - **For SwornDisk**: Resets the device using `reset_sworn.sh` to prevent space exhaustion
   - **For CryptDisk**: No reset needed (in-place encryption)
4. Generates `benchmark_results/result.json`

## Usage

### Run Benchmark

**Note**: You must run the benchmark with root/sudo privileges for block device access:

```bash
cd trace
sudo ./run_trace_benchmark.sh
```

The script will:
1. Compile trace.cpp
2. Verify trace data files exist
3. Verify block devices are accessible
4. Run all 5 traces on both disk types
   - After each SwornDisk trace test, the device is reset using `reset_sworn.sh`
   - CryptDisk tests run without device reset
5. Generate results in `benchmark_results/result.json`

**Note**: Each trace test operates on the block device directly (up to 50GB device size).

### Plot Results

After the benchmark completes:

```bash
python3 plot_result.py
```

Or with custom paths:

```bash
python3 plot_result.py --input benchmark_results/result.json --output result.png
```

The chart will be saved as `result.png` showing throughput for all traces and an average.

## Output

### JSON Results

The benchmark generates `benchmark_results/result.json`:

```json
[
  {
    "trace": "hm_0",
    "disk_type": "sworndisk",
    "bandwidth_mb_s": 125.4
  },
  {
    "trace": "hm_0",
    "disk_type": "cryptdisk",
    "bandwidth_mb_s": 118.2
  },
  ...
]
```

All bandwidth values are in MiB/s.

### Chart

The plot script generates a bar chart with:
- X-axis: Trace names (hm, mds, prn, wdev, web, avg)
- Y-axis: Throughput (MB/s)
- Two bars per trace: CryptDisk (red) and SwornDisk (blue)

## File Structure

```
trace/
├── trace.cpp                  # C++ trace replay program
├── run_trace_benchmark.sh     # Main benchmark script
├── plot_result.py             # Plotting script
├── msr-test/                  # Trace data files (*.csv)
├── benchmark_results/
│   ├── result.json            # Benchmark results
│   └── *_output.txt           # Raw program output logs
└── README.md                  # This file
```

## Notes

- **Direct block device testing**: Tests run directly on `/dev/mapper/test-sworndisk` and `/dev/mapper/test-crypt`, not on filesystems
- **SwornDisk reset**: After each trace test, SwornDisk is reset to prevent space exhaustion and ensure clean state for next test
- **CryptDisk behavior**: No reset needed as CryptDisk uses in-place encryption
- SwornDisk includes a warmup phase to initialize unwritten blocks
- CryptDisk skips warmup (standard block device behavior)
- Test duration depends on trace size (typically 5-30 minutes per trace)
- Block device size: up to 50GB (defined in trace.cpp)
- **Requires root access**: Block device operations require sudo/root privileges

## Customization

### Device Paths

To change device paths, edit the top of `run_trace_benchmark.sh`:

```bash
# ============================================================
# DEVICE PATH CONFIGURATION (modify these paths as needed)
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"
```

### Reset Script Location

If your `reset_sworn.sh` is in a different location, update:

```bash
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"
```

### Trace Selection

To test different trace variants or add new traces, edit:

```bash
TRACES=("hm_0" "mds_0" "prn_0" "wdev_0" "web_0")
```

## Troubleshooting

### Compilation Errors

If compilation fails:
```bash
g++ --version  # Check g++ is installed
sudo apt install -y build-essential
```

### Trace Files Not Found

If trace files are missing, you need to obtain the MSR Cambridge trace dataset and place the `msr-test` directory containing `*.csv` files in this directory.

### Block Devices Not Found

Ensure block devices are set up correctly:
```bash
# Check if devices exist
ls -l /dev/mapper/test-sworndisk
ls -l /dev/mapper/test-crypt

# Check device status
sudo dmsetup status test-sworndisk
sudo dmsetup status test-crypt

# If devices don't exist, initialize them
sudo ../reset_sworn.sh
sudo ../reset_crypt.sh
```

### Permission Denied

If you get permission errors, ensure you're running with sudo:
```bash
sudo ./run_trace_benchmark.sh
```

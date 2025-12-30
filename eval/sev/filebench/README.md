# Filebench Benchmark for SEV

This directory contains scripts to benchmark SwornDisk and CryptDisk using Filebench workloads on mounted filesystems.

## Overview

Filebench is a file system and storage benchmark that can generate complex workloads. This benchmark tests filesystems mounted on block devices:
- **SwornDisk**: `/dev/mapper/test-sworndisk` mounted at `/root/sworndisk`
- **CryptDisk**: `/dev/mapper/test-crypt` (dm-crypt + dm-integrity) mounted at `/root/cryptdisk`

Tests run on filesystems (ext4) mounted on these block devices, providing filesystem-level performance measurements with real-world workload patterns.

## Workloads

Four Filebench workloads are tested:
- **fileserver**: File server workload (create, write, read, delete operations)
  - 10000 files, 16 threads, 60 seconds runtime
- **varmail**: Mail server workload (create, write, read, delete operations)
  - 8000 files, 16 threads, 60 seconds runtime
- **oltp**: OLTP database workload (random read/write)
  - 100 data files, 10 writers + 20 readers, 60 seconds runtime
- **videoserver**: Video server workload (read/write)
  - 35 video files (1GB each), 48 reader threads + 1 writer, 60 seconds runtime

## Prerequisites

1. Install Filebench (choose one method):

   **Method 1: From package manager (recommended for quick start)**
   ```bash
   sudo apt install -y filebench
   ```

   **Method 2: Build from source (for latest version)**
   ```bash
   cd filebench
   ./download_and_build_filebench.sh
   ```

   This will:
   - Install build dependencies (bison, flex, libtool, automake)
   - Download Filebench 1.5-alpha3 source
   - Build and install to /usr/local/bin

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

4. Mount filesystems on block devices:
   ```bash
   # Mount filesystems (creates ext4 filesystems and mounts them)
   sudo ../mount_filesystems.sh
   ```

   This will mount:
   - SwornDisk at `/root/sworndisk`
   - CryptDisk at `/root/cryptdisk`

5. **Root/sudo access required**: Filesystem mounting and block device operations require root permissions

## How It Works

### Workload Templates

Workload template files (in `workloads/`) contain Filebench configuration with a placeholder `$BENCHMARK_DIR$`. The test script replaces this with the actual test directory path for each disk type.

### Test Script (run_filebench_benchmark.sh)

The script:
1. Checks for Filebench installation
2. Checks if filesystems are mounted (if not, mounts them automatically)
3. For each workload and disk type:
   - Checks mount point is accessible
   - Generates a workload file with the correct path
   - Cleans up the test directory
   - Runs Filebench on the mounted filesystem
   - Collects output
   - Cleans up after test
   - **For SwornDisk**: Unmounts filesystem, resets device using `reset_sworn.sh`, remounts filesystem
   - **For CryptDisk**: No reset needed (in-place encryption)
4. Parses results using `parse_filebench_results.sh`
5. Generates `benchmark_results/result.json`

### Parse Script (parse_filebench_results.sh)

Extracts metrics from Filebench output:
- Throughput (MB/s)
- Operations per second (ops/s)
- Latency (ms/op)

### Plot Script (plot_result.py)

Generates a bar chart comparing SwornDisk and CryptDisk across all workloads.

## Usage

### Run All Workloads

**Note**: You must run the benchmark with root/sudo privileges for filesystem and block device operations:

```bash
cd filebench
sudo ./run_filebench_benchmark.sh
```

This will run all 4 workloads on both disk types (8 tests total).

The script will:
- Check if filesystems are mounted, and mount them if needed
- Run each workload on SwornDisk and CryptDisk
- After each SwornDisk workload: unmount, reset device, remount filesystem
- CryptDisk workloads run without device reset

### Run Single Workload

```bash
sudo ./run_filebench_benchmark.sh fileserver
sudo ./run_filebench_benchmark.sh oltp
sudo ./run_filebench_benchmark.sh varmail
sudo ./run_filebench_benchmark.sh videoserver
```

### Plot Results

After the benchmark completes:

```bash
python3 plot_result.py
```

Or with custom paths:

```bash
python3 plot_result.py --input benchmark_results/result.json --output result.png
```

The chart will be saved as `result.png`.

## Output

### JSON Results

The benchmark generates `benchmark_results/result.json`:

```json
[
  {
    "workload": "fileserver",
    "disk_type": "sworndisk",
    "throughput_mb_s": 165.0,
    "ops_per_s": 6845.3,
    "latency_ms": 7.8
  },
  {
    "workload": "fileserver",
    "disk_type": "cryptdisk",
    "throughput_mb_s": 158.2,
    "ops_per_s": 6512.1,
    "latency_ms": 8.2
  },
  ...
]
```

### Chart

The plot script generates a bar chart with:
- X-axis: Workload names (fileserver, varmail, oltp, videoserver)
- Y-axis: Throughput (MB/s)
- Two bars per workload: CryptDisk (red) and SwornDisk (blue)

## File Structure

```
filebench/
├── workloads/
│   ├── fileserver-template.f      # Fileserver workload template
│   ├── oltp-template.f             # OLTP workload template
│   ├── varmail-template.f          # Varmail workload template
│   ├── videoserver-template.f      # Videoserver workload template
│   └── *-{disk}.f                  # Generated workload files
├── benchmark_results/
│   ├── result.json                 # Parsed benchmark results
│   └── *_output.txt                # Raw Filebench output logs
├── run_filebench_benchmark.sh      # Main benchmark script
├── parse_filebench_results.sh      # Result parsing script
├── plot_result.py                  # Plotting script
├── download_and_build_filebench.sh # Build filebench from source
├── preinstall_deps.sh              # Install build dependencies
└── README.md                       # This file
```

## Notes

- **Filesystem testing**: Tests run on ext4 filesystems mounted on block devices
- **Mount points**: `/root/sworndisk` and `/root/cryptdisk`
- **SwornDisk reset**: After each workload, SwornDisk filesystem is unmounted, device is reset, then remounted to prevent space exhaustion
- **CryptDisk behavior**: No reset needed as CryptDisk uses in-place encryption
- Test directories are cleaned before and after each test
- Each workload runs for **60 seconds**
- **Multi-threaded** workloads (16-48 threads depending on workload)
- **File pre-allocation** enabled for most workloads
- Complex file operations including writewholefile, appendfilerand, fsync
- **Requires root access**: Filesystem mounting and block device operations require sudo/root privileges
- **Estimated test duration: ~10-15 minutes for all workloads** (including reset/remount time)

## Customization

### Device and Mount Paths

To change device paths and mount points, edit the top of `run_filebench_benchmark.sh`:

```bash
# ============================================================
# DEVICE PATH CONFIGURATION (modify these paths as needed)
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
CRYPTDISK_DEVICE="/dev/mapper/test-crypt"

# Mount points for filesystems
SWORNDISK_MOUNT="/root/sworndisk"
CRYPTDISK_MOUNT="/root/cryptdisk"
```

### Reset and Mount Scripts

If your scripts are in different locations, update:

```bash
RESET_SWORN_SCRIPT="${SCRIPT_DIR}/../reset_sworn.sh"
MOUNT_SCRIPT="${SCRIPT_DIR}/../mount_filesystems.sh"
```

### Modify Workload Parameters

Edit the template files in `workloads/`. For example, in `fileserver-template.f`:

```bash
set $nfiles=10000         # Number of files
set $nthreads=16          # Number of threads
set $filesize=128k        # File size
run 60                    # Runtime in seconds
```

**To reduce test intensity for faster testing:**
- Reduce file count: `set $nfiles=1000`
- Reduce threads: `set $nthreads=4`
- Reduce runtime: `run 20`

**To increase test intensity:**
- Increase file count: `set $nfiles=20000`
- Increase threads: `set $nthreads=32`
- Increase runtime: `run 120`

### Add New Workloads

1. Copy an existing template file
2. Modify parameters as needed
3. Add the workload name to `WORKLOADS` array in `run_filebench_benchmark.sh`

## Troubleshooting

### Filebench Not Found

If filebench is not installed:
```bash
sudo apt install -y filebench
```

### Filesystems Not Mounted

If the script reports filesystems are not mounted:
```bash
# Check mount status
mount | grep -E "sworndisk|cryptdisk"

# Mount filesystems manually
sudo ../mount_filesystems.sh

# Verify mounts
df -h | grep -E "sworndisk|cryptdisk"
```

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

Ensure you're running with sudo:
```bash
sudo ./run_filebench_benchmark.sh
```

### Filebench Crashes or Hangs

- Check if there's enough space on mounted filesystems (videoserver needs ~35GB+ per filesystem)
  ```bash
  df -h /root/sworndisk /root/cryptdisk
  ```
- SwornDisk may exhaust space quickly - the device will be reset after each workload automatically
- Try reducing the number of files or threads in template files
- Try reducing prealloc percentage or removing it: `prealloc=50` or no prealloc parameter
- For videoserver, reduce file size: `set $filesize=128m` instead of 1g
- Check system logs: `dmesg | tail`

### No Results in JSON

Check the raw output files in `benchmark_results/*_output.txt` for errors. The parse script looks for "IO Summary" lines in the output.

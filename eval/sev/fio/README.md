# FIO Benchmark for SEV

This directory contains scripts to benchmark SwornDisk and CryptDisk using FIO (Flexible I/O Tester) with direct block device access.

## Overview

The benchmark tests raw block device performance by directly accessing device mapper devices, comparing:
- **SwornDisk**: `/dev/mapper/test-sworndisk`
- **CryptDisk**: `/dev/mapper/test-crypt` (dm-crypt + dm-integrity)

The tests run directly on block devices without filesystem overhead, providing more accurate low-level I/O performance measurements.

## Test Configuration

### Write Tests
- Sequential Write (256KB blocks)
- Random Write (4KB, 32KB, 256KB blocks)

**For SwornDisk**: Each write test is followed by a device reset using `reset_sworn.sh` to ensure clean state and prevent space exhaustion.

**For CryptDisk**: No reset needed as it's in-place encryption.

### Read Tests
- Sequential Read (256KB blocks)
- Random Read (4KB, 32KB, 256KB blocks)

Read tests prepare data once, then run all tests sequentially on the same data. **No device reset is performed for read tests.**

## Prerequisites

1. Install FIO:
   ```bash
   sudo apt install -y fio
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
   ./reset_sworn.sh

   # Initialize CryptDisk (if needed)
   ./reset_crypt.sh
   ```

4. **Root/sudo access required**: Direct block device access requires root permissions

## Usage

### Run Benchmark

**Note**: You must run the benchmark with root/sudo privileges for block device access:

```bash
cd fio
sudo ./run_fio_benchmark.sh
```

The script will:
1. Check for FIO installation
2. Verify block devices are accessible
3. Run write tests on both devices
   - For SwornDisk: After each write test, the device is reset using `reset_sworn.sh`
   - For CryptDisk: No reset needed (in-place encryption)
4. Run read tests (preparing data once for all read tests)
5. Generate results in `benchmark_results/result.json`

### Plot Results

After the benchmark completes:

```bash
python3 plot_result.py
```

Or with custom paths:

```bash
python3 plot_result.py --input benchmark_results/result.json --output result.png
```

The chart will be saved as `result.png` showing:
- (a) Writes in SEV
- (b) Reads in SEV

## Output

### JSON Results

The benchmark generates `benchmark_results/result.json`:

```json
[
  {
    "disk_type": "sworndisk",
    "seq_write_256k": 500.2,
    "rand_write_4k": 45.3,
    "rand_write_32k": 120.5,
    "rand_write_256k": 380.1,
    "seq_read_256k": 600.5,
    "rand_read_4k": 55.2,
    "rand_read_32k": 140.3,
    "rand_read_256k": 450.7
  },
  {
    "disk_type": "cryptdisk",
    ...
  }
]
```

All values are in MiB/s.

### Chart

The plot script generates a bar chart comparing SwornDisk and CryptDisk across all test cases.

## File Structure

```
fio/
├── configs/
│   ├── reproduce.fio          # Write test configuration
│   └── reproduce-read.fio     # Read test configuration
├── benchmark_results/
│   ├── result.json            # Benchmark results
│   └── *_output.txt           # Raw FIO output logs
├── run_fio_benchmark.sh       # Main benchmark script
├── plot_result.py             # Plotting script
└── README.md                  # This file
```

## Notes

- **Direct block device testing**: Tests run directly on `/dev/mapper/test-sworndisk` and `/dev/mapper/test-crypt`, not on filesystems
- **SwornDisk reset**: After each write test, SwornDisk is reset to prevent space exhaustion
- **CryptDisk behavior**: No reset needed as CryptDisk uses in-place encryption
- **Read tests**: No device reset performed for read-only operations
- Tests run with `direct=1` to bypass page cache
- Default test duration: 10 seconds per test
- Default test size: 4GB
- **Requires root access**: Block device operations require sudo/root privileges

## Customization

### Test Parameters

To adjust test parameters, edit `configs/reproduce.fio` and `configs/reproduce-read.fio`:
- `runtime`: Test duration in seconds (default: 10s)
- `size`: Test size (default: 4GB)
- `bs`: Block size (varies by test: 4k, 32k, 256k)
- `direct`: Direct I/O flag (1=bypass cache, 0=use cache)

### Device Paths

To change device paths, edit the top of `run_fio_benchmark.sh`:

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


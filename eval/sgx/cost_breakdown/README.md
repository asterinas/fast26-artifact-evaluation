# Cost Statistics Benchmark

This benchmark uses FIO to test disk I/O performance and collect cost statistics for different workload patterns.

## Overview

The benchmark tests four workload patterns:
- **Sequential Read**: Large block sequential reads (128K)
- **Sequential Write**: Large block sequential writes (128K)
- **Random Read**: Small block random reads (4K)
- **Random Write**: Small block random writes (4K)

Each test runs for 30 seconds on a 50GB SwornDisk with `stat_cost` enabled.

## Prerequisites

1. FIO must be built first. If not already built:
   ```bash
   cd ../fio
   ./download_and_build_fio.sh
   ```

2. Occlum must be installed and configured.

## Running the Benchmark

Run all four tests:
```bash
./run_cost_benchmark.sh
```

This will:
1. Create a fresh Occlum instance for each test
2. Configure a 50GB disk with `stat_cost` enabled
3. Run the FIO workload
4. Save results to `results/` directory

## Results

Results are saved in the `results/` directory:
- `seq-read.log` - Sequential read test output
- `seq-write.log` - Sequential write test output
- `rand-read.log` - Random read test output
- `rand-write.log` - Random write test output

### Cost Statistics Output

At the end of each test log, you'll find cost statistics showing:

**L3 (Disk Layer) Cost Statistics:**
- Logical Block Table: Time spent on LSM tree operations
- Block I/O: Time spent on actual disk I/O
- Encryption: Time spent on encryption/decryption
- Allocation: Time spent on block allocation

**L2 (LSM Tree Layer) Cost Statistics:**
- WAL: Write-Ahead Log operations
- MemTable: In-memory table operations
- Compaction: LSM tree compaction
- SSTable Lookup: SSTable search operations

Each metric shows:
- Absolute time (milliseconds)
- Percentage of total cost

## Configuration

### Disk Size
The disk is configured to 50GB in `run_cost_benchmark.sh`:
```json
{
  "disk_size": "50GB",
  "disk_name": "sworndisk",
  "stat_cost": true
}
```

### Test Parameters
Modify the FIO config files in `configs/` to adjust:
- `runtime`: Test duration (default: 30 seconds)
- `bs`: Block size (128K for sequential, 4K for random)
- `size`: File size (default: 10G)
- `numjobs`: Number of parallel jobs

### Example: Changing Runtime
Edit `configs/seq-read.fio`:
```ini
runtime=60  # Change from 30 to 60 seconds
```

## Understanding the Results

### Performance Metrics (from FIO)
- **IOPS**: I/O operations per second
- **Bandwidth**: MB/s throughput
- **Latency**: Average, min, max latencies

### Cost Breakdown
The cost statistics help identify bottlenecks:
- High **Encryption** cost: Crypto operations are the bottleneck
- High **Block I/O** cost: Disk I/O is the bottleneck
- High **Logical Block Table** cost: LSM tree operations dominate
- High **Allocation** cost: Block management overhead

## Troubleshooting

**FIO not found:**
```bash
cd ../fio && ./download_and_build_fio.sh
```

**Disk size too small:**
Edit `run_cost_benchmark.sh` and increase `disk_size`.

**Out of memory:**
Reduce the file size in config files or increase `user_space_size` in the script.

## Comparing with Native Performance

To compare with native Linux performance:
```bash
# Install fio on host
sudo apt-get install fio

# Run native test
fio configs/seq-read.fio
```

Note: Native FIO config may need path adjustments (`/ext2/` → `/tmp/`).

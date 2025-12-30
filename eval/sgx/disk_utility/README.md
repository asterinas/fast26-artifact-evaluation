# Disk Aging Experiment for SwornDisk

This experiment measures the impact of disk fill level (disk aging) on write throughput performance of SwornDisk.

## Overview

The disk aging experiment simulates real-world disk usage patterns by progressively filling the disk and measuring write performance at each fill level. This helps understand how SwornDisk's LSM-tree based architecture handles write amplification and compaction overhead as the disk becomes fuller.

## Experiment Design

- **Disk Size**: 50GB (configurable)
- **Fill Step**: 10% of total disk capacity
- **Fill Levels**: 10%, 20%, 30%, ..., 90%
- **Fill Method**: Sequential Write (256KB blocks) - fast disk filling
- **Test Method**: Random Write (4KB blocks) - performance measurement

### Methodology

At each fill level, the experiment:
1. **Creates** a fresh Occlum instance with a new SwornDisk
2. **Fills** the disk to the target level using sequential writes
3. **Tests** random write performance at that fill level (1GB test)
4. **Saves** the result immediately to CSV
5. **Cleans up** the instance and repeats for the next fill level
6. **Generates** JSON report from CSV after all tests complete

**Why fresh instances?** SwornDisk is append-only, so random writes would interfere with the disk fill level. By using a fresh instance for each test, we ensure accurate fill levels and clean measurements.

**Why save incrementally?** Results are saved to CSV after each test, so if the experiment is interrupted, you won't lose all data. The JSON report is generated at the end from the CSV file.

This approach simulates real-world disk aging where the disk is gradually filled with data, and we measure how performance degrades as the disk becomes fuller.

## Expected Behavior

Based on LSM-tree characteristics, as the disk fills up:
- **Write Amplification** increases due to more frequent compactions
- **Random Write Throughput** degrades as the LSM tree becomes deeper
- **Performance degradation** should be gradual and predictable

Similar to StrataDisk (Figure 15), we expect:
- Throughput to decrease as disk utilization increases
- More pronounced degradation at higher fill levels (70-90%)

## Prerequisites

1. **FIO must be built**: The experiment uses FIO from `../fio/fio_src/fio`
   ```bash
   cd ../fio
   ./download_and_build_fio.sh
   cd ../disk_age
   ```

2. **Occlum environment**: Ensure Occlum is properly installed and configured

## Usage

### Test the setup (recommended first):
```bash
./test_setup.sh
```

This will verify that all dependencies are installed and configured correctly.

### Run the full experiment:
```bash
./run_disk_age.sh
```

**Note**: The full experiment can take several hours depending on disk size and system performance.

### Configuration

Edit the following variables in `run_disk_age.sh` to customize the experiment:

```bash
DISK_SIZE_GB=50           # Total disk size
DISK_NAME="sworndisk"     # Disk type (sworndisk or cryptdisk)
FILL_STEP_PERCENT=10      # Percentage to fill at each step
MAX_FILL_PERCENT=90       # Maximum fill level
```

## Output

The experiment generates two output files in the `results/` directory:

### 1. CSV Format (`disk_age_results.csv`)
```csv
disk_name,fill_percent,throughput_mbs
sworndisk,10,450.3
sworndisk,20,448.5
sworndisk,30,445.8
sworndisk,40,442.4
...
sworndisk,90,419.1
```

### 2. JSON Format (`disk_age_results.json`)
```json
{
  "disk_size_gb": 50,
  "fill_step_percent": 10,
  "results": {
    "sworndisk": {
      "fill_levels": [10, 20, 30, 40, 50, 60, 70, 80, 90],
      "throughputs": [450.3, 448.5, 445.8, 442.4, 438.7, 434.2, 429.5, 424.3, 419.1]
    },
    "cryptdisk": {
      "fill_levels": [10, 20, 30, 40, 50, 60, 70, 80, 90],
      "throughputs": [380.2, 378.1, 375.5, 372.3, 368.9, 365.1, 361.2, 356.8, 352.4]
    }
  }
}
```

**Note**: The JSON format groups results by `disk_name`, allowing you to compare different disk types (e.g., `sworndisk` vs `cryptdisk`) in the same file.

**Note**: The results show random write throughput at each disk fill level. The disk is filled using sequential writes (fast), then performance is measured using random writes (realistic workload).

## Visualization

After the experiment completes, visualize the results:

```bash
./plot_results.py results/disk_age_results.json
```

This generates two plots:
1. **disk_aging_throughput.png**: Absolute throughput vs. disk fill level
2. **disk_aging_degradation.png**: Relative performance degradation (normalized to 10% fill)

The plots are similar to StrataDisk paper Figure 15:
- **Throughput Plot**: Shows how write performance changes as disk fills up
- **Degradation Plot**: Shows relative performance loss compared to baseline

### Manual Visualization

You can also create custom plots using the JSON output:

```python
import json
import matplotlib.pyplot as plt

with open('results/disk_age_results.json', 'r') as f:
    data = json.load(f)

for test_type, results in data['results'].items():
    plt.plot(results['fill_levels'], results['throughputs'],
             marker='o', label=test_type)

plt.xlabel('Disk Utilization (%)')
plt.ylabel('Throughput (MB/s)')
plt.title('SwornDisk Aging: Throughput vs. Disk Fill Level')
plt.legend()
plt.grid(True)
plt.savefig('custom_plot.png')
```

## Interpretation

- **Stable Performance**: Indicates good garbage collection and compaction strategies
- **Gradual Degradation**: Expected for LSM-tree based systems due to increased compaction overhead
- **Sharp Drops**: May indicate inefficient space reclamation or excessive write amplification

## Notes

- The experiment takes significant time to complete (several hours for 80GB disk)
- Ensure sufficient host disk space for the disk image file
- The first run will initialize the Occlum instance and may take longer
- Results may vary based on system resources and cache configuration

## Troubleshooting

**Error: fio not found**
```bash
cd ../fio && ./download_and_build_fio.sh
```

**Error: Disk size too small**
- Minimum disk size for SwornDisk is 5GB
- Adjust `DISK_SIZE_GB` in the script

**Out of memory errors**
- Reduce `DISK_SIZE_GB`
- Increase Occlum memory limits in the script

## References

- SwornDisk Paper: [Add reference]
- StrataDisk Disk Aging Analysis: Figure 15
- FIO Documentation: https://fio.readthedocs.io/


# SwornDisk Optimization Benchmark

This benchmark tests the performance impact of two SwornDisk optimization features:

## Tests

### 1. delayed_reclamation (4K Random Write)
Tests the impact of delayed block reclamation on write performance.

- **Test**: 4K random write for 30 seconds on 10GB file
- **Configurations**:
  - `delayed_reclamation=false` (baseline)
  - `delayed_reclamation=true` (optimized)
- **Expected**: Delayed reclamation should improve write throughput by reducing immediate block reclamation overhead

### 2. two_level_caching (4K Random Read)
Tests the impact of two-level caching on read performance.

- **Test**: 4K random read for 30 seconds on 10GB file
- **Configurations**:
  - `two_level_caching=false` (baseline)
  - `two_level_caching=true` (optimized)
- **Expected**: Two-level caching should improve read throughput by providing better cache locality

## Running the Benchmark

```bash
cd /root/occlum/demos/benchmarks/optimization
./run_optimization_benchmark.sh
```

## Results

Results are saved to `results/` directory with the following files:
- `rand-write-4k-delayed_reclamation_false.log`
- `rand-write-4k-delayed_reclamation_true.log`
- `rand-read-4k-two_level_caching_false.log`
- `rand-read-4k-two_level_caching_true.log`
- `optimization_results.json` (throughput summary for plotting)

## Key Metrics

Look for these metrics in FIO output:

- **IOPS**: Operations per second (higher is better)
- **BW**: Bandwidth/throughput in MB/s (higher is better)
- **LAT**: Latency in microseconds (lower is better)
  - avg: Average latency
  - min/max: Min/max latency
  - stdev: Standard deviation

## Example Comparison

```bash
# Compare write performance
grep "write:" results/rand-write-4k-delayed_reclamation_*.log

# Compare read performance
grep "read:" results/rand-read-4k-two_level_caching_*.log
```

# Cache Size Benchmark

Runs 4KB random write and read fio workloads across cache sizes for `PfsDisk`, `sworndisk`, and `cryptdisk`.

## Run
```
cd eval/cache_size
./reproduce.sh
```

## Output
- Results JSON: `benchmark_results/cache_size_result.json`
- Raw fio logs: `benchmark_results/${disk}_cache${size}_{randwrite|randread}.txt`

Only throughput (MiB/s) is recorded in the JSON for plotting.

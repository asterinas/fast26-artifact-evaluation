# Filebench

Tests filesystem performance using [Filebench](https://github.com/Filebench/Filebench) workloads: `fileserver`, `oltp`, `varmail`, `videoserver`.

## Run

Step 1: Install dependencies and build Filebench (skip if already built)
```bash
./preinstall_deps.sh
./dl_and_build_filebench.sh
```

Step 2: Run benchmarks
```bash
./reproduce.sh
```

Step 3: Plot results
```bash
python3 plot_result.py
```

## Output

- Results JSON: `results/filebench_results.json`
- Raw logs: `results/${workload}_${disk}_output.txt`
- Plot: `result.png`

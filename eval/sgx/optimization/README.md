# StrataDisk Optimization

Tests the performance impact of two StrataDisk optimization features:
- `delayed_reclamation`: 4KB random write performance
- `two_level_caching`: 4KB random read performance

## Prerequisites

FIO must be built first:
```bash
cd ../fio && ./download_and_build_fio.sh
```

## Run

```bash
./reproduce.sh
```

## Plot

```bash
python3 plot_result.py
```

## Output

- Results JSON: `results/optimization_results.json`
- Raw logs: `results/rand-{write|read}-4k-*.log`
- Plot: `result.png`

# Cache Size Sensitivity

Tests 4KB random write/read performance across different cache sizes (256MB - 1536MB) for PfsDisk, StrataDisk, and CryptDisk.

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

- Results JSON: `results/cache_size_result.json`
- Raw FIO logs: `results/${disk}_cache${size}_rand{write|read}.txt`
- Plot: `result.png`

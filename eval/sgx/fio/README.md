# FIO Micro-benchmarks

Tests sequential/random read/write performance on PfsDisk, StrataDisk, and CryptDisk using [FIO](https://github.com/axboe/fio).

## Run

Step 1: Build FIO (skip if already built)
```bash
./download_and_build_fio.sh
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

- Results JSON: `results/reproduce_result.json`
- Raw FIO logs: `results/${disk}_${test}_output.txt`
- Plot: `result.png`

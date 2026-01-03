# Disk Utility (Aging)

Measures throughput and Write Amplification Factor (WAF) as disk fills from 10% to 90% for StrataDisk and CryptDisk.

## Prerequisites

FIO must be built first:
```bash
cd ../fio && ./download_and_build_fio.sh
```

## Run

```bash
./reproduce.sh
```

The experiment creates fresh Occlum instances at each fill level to ensure accurate measurements.

## Plot

```bash
python3 plot_result.py
```

## Output

- Results CSV: `results/reproduce_results.csv`
- Raw logs: `results/${disk}_task1_throughput.txt`, `results/${disk}_task2_waf.txt`
- Plot: `result.png`

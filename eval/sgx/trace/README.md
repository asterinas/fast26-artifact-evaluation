# MSR Trace Replay

Replays MSR Cambridge traces (`hm_0`, `mds_0`, `prn_0`, `wdev_0`, `web_0`) on PfsDisk, StrataDisk, and CryptDisk.

## Prerequisites

Trace files must be available in `msr-test/`. If missing, download from [SNIA IOTTA](https://iotta.snia.org/traces/block-io/388) and place the CSV files there.

## Run

```bash
./reproduce.sh
```

## Plot

```bash
python3 plot_result.py
```

## Output

- Results JSON: `results/trace_reproduce_result.json`
- Raw logs: `results/${trace}_${disk}_output.txt`
- Plot: `result.png`

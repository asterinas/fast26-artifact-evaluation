  # Cleaning (GC Interval)

  Tests the impact of garbage collection intervals on StrataDisk write throughput.

  Configurations tested:
  - GC disabled
  - GC enabled with intervals: 30s, 60s, 90s

  ## Run

  ```bash
  ./reproduce.sh
  ```
  
  ## Plot

  ```bash
  python3 plot_result.py
  ```

  ## Output

  - Results CSV: `results/throughput_gc_off.csv`, `results/throughput_interval_*.csv`
  - Plot: `result.png`
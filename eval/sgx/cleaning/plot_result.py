#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np

def load_throughput(path: Path):
    """Load throughput values from CSV file (one value per line)."""
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        values = [float(line.strip()) for line in f if line.strip()]
    return values

def plot_cleaning_results(results_dir: Path, out_path: Path):
    """Plot throughput over rounds for different configurations."""

    # Define configurations to plot
    configs = [
        ("throughput_gc_off.csv", "GC Off", "#e74c3c", "o"),
        ("throughput_interval_30.csv", "Interval 30s", "#2ecc71", "s"),
        ("throughput_interval_60.csv", "Interval 60s", "#3498db", "^"),
        ("throughput_interval_90.csv", "Interval 90s", "#9b59b6", "D"),
    ]

    fig, ax = plt.subplots(figsize=(10, 6))

    max_rounds = 0
    for filename, label, color, marker in configs:
        filepath = results_dir / filename
        values = load_throughput(filepath)
        if values is None:
            print(f"Warning: {filepath} not found, skipping")
            continue

        rounds = list(range(len(values)))
        max_rounds = max(max_rounds, len(values))
        ax.plot(rounds, values, label=label, color=color, marker=marker,
                linewidth=2, markersize=8)

    # Styling
    ax.set_xlabel('Round', fontsize=14)
    ax.set_ylabel('Throughput (MiB/s)', fontsize=14)
    ax.set_title('Cleaning Benchmark: Throughput over Rounds', fontsize=16, fontweight='bold')

    # X-axis ticks
    if max_rounds > 0:
        ax.set_xticks(range(max_rounds))

    # Grid
    ax.grid(True, linestyle='--', alpha=0.7)
    ax.set_axisbelow(True)

    # Legend
    ax.legend(loc='best', fontsize=12, frameon=True)

    # Remove top and right spines
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    plt.tight_layout()
    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Chart saved to {out_path}")

def main():
    parser = argparse.ArgumentParser(description="Plot cleaning benchmark results")
    parser.add_argument("--input", default="results", type=Path,
                        help="Directory containing throughput CSV files")
    parser.add_argument("--output", default="result.png", type=Path,
                        help="Output image path")
    args = parser.parse_args()

    try:
        plot_cleaning_results(args.input, args.output)
    except Exception as e:
        sys.stderr.write(f"Error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()

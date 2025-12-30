#!/usr/bin/env python3
"""
Plot merged YCSB results for SwornDisk vs CryptDisk (Targeting StrataDisk style).

Generates a single image with 4 subplots:
(a) BoltDB, (b) SQLite, (c) PostgreSQL, (d) RocksDB
"""

import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple, Optional

import matplotlib.pyplot as plt
import numpy as np

# --- Configuration to match the target image ---
WORKLOAD_ORDER = ["workloada", "workloadb", "workloade", "workloadf"]
WORKLOAD_LABELS = ["YCSB-A", "YCSB-B", "YCSB-E", "YCSB-F"]

# Map JSON keys to Legend Labels
# We read "SwornDisk" from JSON, but plot "StrataDisk" to match the image
FS_KEYS = ["CryptDisk", "SwornDisk"] 
FS_LEGEND_LABELS = ["CryptDisk", "StrataDisk"] 

# Styling
COLORS = ["#e74c3c", "#5d8aa8"]  # Red-ish, Blue-ish
HATCHES = ["||||", "////"]       # Vertical for Crypt, Diagonal for Strata
BAR_WIDTH = 0.35

def load_results(path: Path) -> Dict[str, Dict[str, float]]:
    """Load a results JSON file and return data[fs][workload] in kops."""
    if not path.exists():
        print(f"Warning: File not found {path}")
        return {fs: {wl: 0.0 for wl in WORKLOAD_ORDER} for fs in FS_KEYS}

    with open(path, "r") as f:
        data = json.load(f)

    results = data.get("results", [])
    
    # Initialize with 0.0
    plot_dict = {fs: {wl: 0.0 for wl in WORKLOAD_ORDER} for fs in FS_KEYS}

    for entry in results:
        wl = entry.get("workload")
        fs = entry.get("filesystem")
        thr = entry.get("throughput_ops_sec")
        
        if wl in WORKLOAD_ORDER and fs in FS_KEYS and thr is not None:
            # Convert ops/sec to kops (thousands of ops/sec)
            plot_dict[fs][wl] = float(thr) / 1000.0

    return plot_dict

def plot_subplot(ax, data: Dict[str, Dict[str, float]], title_idx: str, title_text: str):
    """Plot a single database onto the given axes."""
    x = np.arange(len(WORKLOAD_ORDER))

    # Plot bars
    for i, (fs_key, legend_label, color, hatch) in enumerate(zip(FS_KEYS, FS_LEGEND_LABELS, COLORS, HATCHES)):
        vals = [data[fs_key][wl] for wl in WORKLOAD_ORDER]
        offset = (i - 0.5) * (BAR_WIDTH + 0.02) # Small gap between bars
        
        ax.bar(
            x + offset,
            vals,
            BAR_WIDTH,
            label=legend_label,
            color="white",      # White background
            edgecolor=color,    # Colored border
            hatch=hatch,        # Colored pattern
            linewidth=1.0,
            zorder=3
        )

    # Y-Axis Formatting
    ax.set_ylabel("Throughput (kops)", fontsize=11, fontweight='bold')
    
    # Auto-scale Y limit with some headroom for the legend
    all_vals = []
    for fs in FS_KEYS:
        all_vals.extend(data[fs].values())
    max_val = max(all_vals) if all_vals else 1.0
    
    # Find a nice upper limit (e.g., round up to nearest 5 or 10)
    if max_val < 10:
        step = 2
    elif max_val < 40:
        step = 5
    else:
        step = 10
    y_limit = ((int(max_val) // step) + 1) * step
    
    # If the bars are very high, give more headroom for the legend
    ax.set_ylim(0, y_limit * 1.15) 

    # X-Axis Formatting
    ax.set_xticks(x)
    ax.set_xticklabels(WORKLOAD_LABELS, fontsize=10, fontweight='bold')
    ax.tick_params(axis="x", length=0) # Hide x ticks marks

    # Grid and Spines
    ax.yaxis.grid(True, linestyle="-", alpha=0.3, zorder=0)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_linewidth(0.5)
    ax.spines["bottom"].set_linewidth(0.5)

    # Legend (Top Center, no frame, parallel columns)
    ax.legend(
        loc="upper center",
        ncol=2,
        frameon=False,
        fontsize=10,
        columnspacing=1.0,
        handletextpad=0.4,
        handlelength=1.5
    )

    # Bottom Title: (a) BoltDB
    # We place this as text below the x-axis
    ax.text(
        0.5, -0.25, 
        f"({title_idx}) {title_text}", 
        transform=ax.transAxes, 
        ha="center", 
        va="top",
        fontsize=16, 
        fontweight="bold"
    )

def main():
    parser = argparse.ArgumentParser(description="Plot merged YCSB benchmark results.")
    parser.add_argument("--bolt", type=Path, default=Path("benchmark_results/boltdb_results.json"))
    parser.add_argument("--sqlite", type=Path, default=Path("benchmark_results/sqlite_results.json"))
    parser.add_argument("--postgres", type=Path, default=Path("benchmark_results/postgres_results.json"))
    parser.add_argument("--rocks", type=Path, default=Path("benchmark_results/rocksdb_results.json"))
    parser.add_argument("--out", type=Path, default=Path("result.png"))

    args = parser.parse_args()

    # Define the order: (a) Bolt, (b) SQLite, (c) Postgres, (d) Rocks
    tasks = [
        ("a", "BoltDB", args.bolt),
        ("b", "SQLite", args.sqlite),
        ("c", "PostgreSQL", args.postgres),
        ("d", "RocksDB", args.rocks),
    ]

    # Create figure: 1 row, 4 columns
    # Adjust figsize to ensure bars aren't too thin. 
    # Width=20, Height=4.5 roughly matches the aspect ratio of the screenshot.
    fig, axes = plt.subplots(1, 4, figsize=(22, 4.5))

    for ax, (idx, name, path) in zip(axes, tasks):
        print(f"Processing {name} from {path}...")
        data = load_results(path)
        plot_subplot(ax, data, idx, name)

    # Layout adjustments
    plt.tight_layout()
    # Add extra margin at bottom for the "(a) Title" labels
    plt.subplots_adjust(bottom=0.2, wspace=0.3)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(args.out, dpi=300, bbox_inches="tight")
    print(f"Success! Combined plot saved to: {args.out}")

if __name__ == "__main__":
    main()
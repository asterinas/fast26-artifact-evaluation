#!/usr/bin/env python3
import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path
import argparse

def load_data(path):
    """Reads JSON and organizes data for plotting (only 2 disk types)."""

    with open(path, "r") as f:
        data = json.load(f)

    # Mapping logic (only SwornDisk and CryptDisk)
    disk_map = {"cryptdisk": "CryptDisk", "sworndisk": "SwornDisk"}

    # Define workload order as seen in reference image
    workload_order = ["fileserver", "varmail", "oltp", "videoserver"]
    disk_types = ["CryptDisk", "SwornDisk"]

    # Initialize data structure
    plot_dict = {dt: {wl: 0.0 for wl in workload_order} for dt in disk_types}

    for entry in data:
        wl = entry["workload"]
        dt = disk_map.get(entry["disk_type"], entry["disk_type"])
        if wl in workload_order and dt in disk_types:
            throughput = entry.get("throughput_mb_s")
            if throughput is not None:
                plot_dict[dt][wl] = throughput

    return workload_order, disk_types, plot_dict

def plot_filebench(workloads, disk_types, plot_dict, save_path):
    """Generates a bar chart matching the reference style (2 disk types)."""
    fig, ax = plt.subplots(figsize=(8, 5))

    # Visual configuration (Only 2 disk types now)
    # CryptDisk: Red/Vertical, SwornDisk: Blue/Diagonal
    colors = ["#e74c3c", "#4a90e2"]  # Red, Blue
    hatches = ["||||", "////"]
    width = 0.35  # Wider bars since we only have 2 disk types
    x = np.arange(len(workloads))

    # Plot grouped bars
    for i, (dt, color, hatch) in enumerate(zip(disk_types, colors, hatches)):
        vals = [plot_dict[dt][wl] for wl in workloads]
        # Calculate horizontal offset for grouping (center the bars)
        offset = (i - 0.5) * (width + 0.05)
        ax.bar(x + offset, vals, width, label=dt,
               color='white', edgecolor=color, hatch=hatch, linewidth=1.5)

    # Axis Labels and ticks
    ax.set_ylabel('Throughput (MB/s)', fontsize=18)
    ax.set_xticks(x)
    ax.set_xticklabels(workloads, fontsize=16)
    ax.tick_params(axis='y', labelsize=16)

    # Set Y-axis limit (Dynamic based on data)
    max_val = max(max(plot_dict[dt].values()) for dt in disk_types)
    y_limit = np.ceil(max_val / 50) * 50  # Round up to nearest 50
    ax.set_ylim(0, y_limit)

    # Background Grid (Horizontal lines only)
    ax.yaxis.grid(True, linestyle='-', alpha=0.3)
    ax.set_axisbelow(True)

    # Remove top and right spines
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Bottom Title
    ax.text(0.5, -0.22, "(a) Filebench in SEV", transform=ax.transAxes,
            fontsize=22, fontweight='bold', ha='center')

    # Legend at the top
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, 1.05),
              ncol=2, frameon=False, fontsize=15, handletextpad=0.3, columnspacing=0.8)

    plt.tight_layout()
    plt.subplots_adjust(bottom=0.2)

    plt.savefig(save_path, dpi=300, bbox_inches='tight')
    print(f"Chart successfully saved to {save_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Plot Filebench results for SwornDisk and CryptDisk")
    parser.add_argument("--input", default="benchmark_results/result.json", type=Path,
                        help="Input JSON file with benchmark results")
    parser.add_argument("--output", default="result.png", type=Path,
                        help="Output PNG file for the chart")
    args = parser.parse_args()

    try:
        wl_order, dt_list, p_data = load_data(args.input)
        if not wl_order or not p_data:
            print("Warning: No valid data found in input file")
            exit(1)
        plot_filebench(wl_order, dt_list, p_data, args.output)
    except Exception as e:
        print(f"An error occurred: {e}")
        import traceback
        traceback.print_exc()
        exit(1)

import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

# 1. Configuration: File paths
input_path = Path("/root/occlum/eval/filebench/results/filebench_results.json")
output_path = Path("result.png")

def load_data(path):
    """Reads JSON and organizes data for plotting."""

    with open(path, "r") as f:
        data = json.load(f)

    # Mapping logic
    disk_map = {"cryptdisk": "CryptDisk", "pfsdisk": "PfsDisk", "sworndisk": "StrataDisk"}
    
    # Define workload order as seen in your reference image
    workload_order = ["fileserver", "varmail", "oltp", "videoserver"]
    disk_types = ["CryptDisk", "PfsDisk", "StrataDisk"]
    
    # Initialize data structure
    plot_dict = {dt: {wl: 0.0 for wl in workload_order} for dt in disk_types}
    
    for entry in data:
        wl = entry["workload"]
        dt = disk_map.get(entry["disk_type"], entry["disk_type"])
        if wl in workload_order and dt in disk_types:
            plot_dict[dt][wl] = entry["throughput_mb_s"]
            
    return workload_order, disk_types, plot_dict

def plot_filebench(workloads, disk_types, plot_dict, save_path):
    """Generates a bar chart matching the reference style."""
    fig, ax = plt.subplots(figsize=(8, 5))

    # Visual configuration (Match reference colors and hatches)
    colors = ["#e74c3c", "#8eb060", "#4a90e2"]  # Red, Green, Blue
    hatches = ["||||", "---", "////"]
    width = 0.22
    x = np.arange(len(workloads))

    # Plot grouped bars
    for i, (dt, color, hatch) in enumerate(zip(disk_types, colors, hatches)):
        vals = [plot_dict[dt][wl] for wl in workloads]
        # Calculate horizontal offset for grouping
        offset = (i - 1) * (width + 0.02)
        ax.bar(x + offset, vals, width, label=dt, 
               color='white', edgecolor=color, hatch=hatch, linewidth=1.2)

    # Axis Labels and ticks
    ax.set_ylabel('Throughput (MB/s)', fontsize=18)
    ax.set_xticks(x)
    ax.set_xticklabels(workloads, fontsize=16)
    ax.tick_params(axis='y', labelsize=16)
    
    # Set Y-axis limit (Fileserver goes up to 221.9, setting to 250 for headroom)
    ax.set_ylim(0, 250)
    ax.set_yticks([0, 50, 100, 150, 200, 250])
    
    # Background Grid (Horizontal lines only)
    ax.yaxis.grid(True, linestyle='-', alpha=0.3)
    ax.set_axisbelow(True)

    # Remove top and right spines
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Bottom Title
    ax.text(0.5, -0.22, "(a) In SGX", transform=ax.transAxes, 
            fontsize=22, fontweight='bold', ha='center')

    # Legend at the top
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, 1.05),
              ncol=3, frameon=False, fontsize=15, handletextpad=0.3, columnspacing=0.8)

    plt.tight_layout()
    plt.subplots_adjust(bottom=0.2) 
    
    plt.savefig(save_path, dpi=300, bbox_inches='tight')
    print(f"Chart saved to {save_path.absolute()}")

if __name__ == "__main__":
    try:
        wl_order, dt_list, p_data = load_data(input_path)
        plot_filebench(wl_order, dt_list, p_data, output_path)
    except Exception as e:
        print(f"An error occurred: {e}")
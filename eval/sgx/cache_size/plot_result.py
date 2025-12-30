import json
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

# 1. Configuration: File paths
input_path = Path("/root/occlum/eval/cache_size/results/cache_size_result.json")
output_path = Path("result.png")

def load_data(path):
    with open(path, "r") as f:
        data = json.load(f)

    # Disk type mapping
    disk_map = {"cryptdisk": "CryptDisk", "pfsdisk": "PfsDisk", "sworndisk": "StrataDisk"}
    
    # Structure: results[op][disk_name] = {cache_gb: throughput}
    results = {"write": {}, "read": {}}
    
    for entry in data:
        op = entry["op"]
        dt = disk_map.get(entry.get("disk_type", "sworndisk"), entry.get("disk_type", "sworndisk"))
        gb = entry["cache_size_mb"] / 1024.0
        val = entry["throughput_mib_s"]
        
        if dt not in results[op]:
            results[op][dt] = {}
        results[op][dt][gb] = val
        
    return results

def plot_cache_benchmark(results, save_path):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Styling constants (Matching image)
    configs = {
        "CryptDisk": {"color": "#e74c3c", "marker": "o"}, # Red Circle
        "PfsDisk":   {"color": "#8eb060", "marker": "s"}, # Green Square
        "StrataDisk": {"color": "#3b75af", "marker": "^"} # Blue Triangle
    }
    
    x_ticks = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]
    disk_order = ["CryptDisk", "PfsDisk", "StrataDisk"]

    # --- Plotting Function for subplots ---
    def draw_subplot(ax, op_type, title, y_limit):
        op_data = results[op_type]
        for dt in disk_order:
            if dt in op_data:
                # Sort data points by cache size
                sorted_x = sorted(op_data[dt].keys())
                sorted_y = [op_data[dt][x] for x in sorted_x]
                ax.plot(sorted_x, sorted_y, label=dt, 
                        color=configs[dt]["color"], 
                        marker=configs[dt]["marker"], 
                        markersize=6, linewidth=1.5)
        
        ax.set_ylabel('Throughput (MB/s)', fontsize=15)
        ax.set_xlabel('Cache size (GB)', fontsize=14)
        ax.set_xticks(x_ticks)
        ax.set_xticklabels([str(t) for t in x_ticks], fontsize=13)
        ax.set_ylim(0, y_limit)
        ax.tick_params(axis='y', labelsize=13)
        
        # Grid and Spines
        ax.yaxis.grid(True, linestyle='-', alpha=0.3)
        ax.set_axisbelow(True)
        ax.spines['top'].set_visible(False)
        ax.spines['right'].set_visible(False)
        
        # Legend at top
        ax.legend(loc='upper center', bbox_to_anchor=(0.5, 1.15),
                  ncol=3, frameon=False, fontsize=12, handletextpad=0.1)
        
        # Bottom label
        ax.text(0.5, -0.25, title, transform=ax.transAxes, 
                fontsize=18, fontweight='bold', ha='center')

    # Draw (a) Writes and (b) Reads
    draw_subplot(ax1, "write", "(a) 4KB random writes", 450)
    draw_subplot(ax2, "read", "(b) 4KB random reads", 200)

    plt.tight_layout()
    plt.subplots_adjust(top=0.82, bottom=0.22, wspace=0.3)
    
    plt.savefig(save_path, dpi=300, bbox_inches='tight')
    print(f"Chart successfully saved to {save_path.absolute()}")

if __name__ == "__main__":
    try:
        benchmark_results = load_data(input_path)
        plot_cache_benchmark(benchmark_results, output_path)
    except Exception as e:
        print(f"An error occurred: {e}")
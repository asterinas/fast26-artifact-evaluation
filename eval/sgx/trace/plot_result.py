import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

# 1. Configuration: File paths
input_path = Path("/root/occlum/eval/trace/results/trace_reproduce_result.json")
output_path = Path("result.png")

def load_and_process_data(path):
    """
    Reads JSON data, maps disk types, and calculates averages.
    """
    with open(path, "r") as f:
        data = json.load(f)

    # Map disk types to display labels
    disk_map = {"cryptdisk": "CryptDisk", "PfsDisk": "PfsDisk", "sworndisk": "StrataDisk"}
    
    # Extract trace names and remove the '_0' suffix
    traces = sorted(list(set(d["trace"].split('_')[0] for d in data)))
    disk_types = ["CryptDisk", "PfsDisk", "StrataDisk"]
    
    # Initialize the data structure for plotting
    plot_data = {dt: {t: 0.0 for t in traces} for dt in disk_types}
    
    for d in data:
        t_name = d["trace"].split('_')[0]
        dt_name = disk_map.get(d["disk_type"], d["disk_type"])
        if dt_name in plot_data and t_name in plot_data[dt_name]:
            plot_data[dt_name][t_name] = d["bandwidth_mb_s"]
            
    # Calculate the average (avg) column
    for dt in disk_types:
        vals = [plot_data[dt][t] for t in traces]
        plot_data[dt]["avg"] = sum(vals) / len(vals)
    
    traces.append("avg")
    return traces, disk_types, plot_data

def plot_trace_results(traces, disk_types, plot_data, save_path):
    """
    Generates a bar chart with specific styling (hatching, colors, layout).
    """
    fig, ax = plt.subplots(figsize=(8, 5))

    # Visual configuration: Match colors and patterns from the reference image
    colors = ["#e74c3c", "#8eb060", "#4a90e2"]  # Red, Green, Blue
    hatches = ["||||", "---", "////"]
    width = 0.25
    x = np.arange(len(traces))

    # Plot grouped bars
    for i, (dt, color, hatch) in enumerate(zip(disk_types, colors, hatches)):
        vals = [plot_data[dt][t] for t in traces]
        # Calculate bar offset
        offset = (i - 1) * (width + 0.02)
        ax.bar(x + offset, vals, width, label=dt, 
               color='white', edgecolor=color, hatch=hatch, linewidth=1)

    # Axis labels and tick formatting
    ax.set_ylabel('Throughput (MB/s)', fontsize=16)
    ax.set_xticks(x)
    ax.set_xticklabels(traces, fontsize=15)
    ax.tick_params(axis='y', labelsize=14)
    
    # Set Y-axis limit: Dynamic adjustment based on data (e.g., wdev is ~1087)
    max_val = max(max(plot_data[dt].values()) for dt in disk_types)
    ax.set_ylim(0, np.ceil(max_val / 200) * 200) 
    
    # Background grid (horizontal lines only)
    ax.yaxis.grid(True, linestyle='-', alpha=0.3)
    ax.set_axisbelow(True)

    # Remove top and right spines for a clean look
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Main title/label at the bottom
    ax.text(0.5, -0.25, "(a) In SGX", transform=ax.transAxes, 
            fontsize=20, fontweight='bold', ha='center')

    # Legend at the top (centered, no frame)
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, 1.05),
              ncol=3, frameon=False, fontsize=14, handletextpad=0.3, columnspacing=0.8)

    plt.tight_layout()
    # Adjust layout to prevent bottom title from being cut off
    plt.subplots_adjust(bottom=0.2) 
    
    # Save as high-resolution image
    plt.savefig(save_path, dpi=300, bbox_inches='tight')
    print(f"Chart successfully saved to {save_path.absolute()}")

if __name__ == "__main__":
    try:
        # 1. Load and process data
        traces, disk_types, plot_data = load_and_process_data(input_path)
        # 2. Generate and save plot
        plot_trace_results(traces, disk_types, plot_data, output_path)
    except Exception as e:
        print(f"Error during execution: {e}")
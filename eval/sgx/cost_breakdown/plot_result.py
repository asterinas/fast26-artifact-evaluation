#!/usr/bin/env python3
"""
Plot cost breakdown charts from benchmark log files.
Updated to match the style of the provided reference image.
"""

import json
import re
import sys
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

# Define test names and labels
TESTS = {
    'seq-write': 'Seq.\nWrite',
    'rand-write': 'Rnd.\nWrite',
    'seq-read': 'Seq.\nRead',
    'rand-read': 'Rnd.\nRead',
}

# L3 Style: Top-to-bottom in image corresponds to reverse order in stack
L3_COMPONENTS = ['allocation', 'encryption', 'block_io', 'logical_block_table']
L3_LABELS = ['Logical Block Table', 'User block I/O', 'User block enc/dec', 'User block allocation']
# Colors matched to the reference (L3: Blue, Salmon, Peach, Gray)
# Re-mapped to match the stack order (bottom component first)
L3_COLORS = ['#cccccc', '#f9cb9c', '#ea9999', '#729fcf']
# Map labels to match the legend order in the image
L3_LEGEND_LABELS = ['Logical Block Table', 'User block I/O', 'User block enc/dec', 'User block allocation']
L3_LEGEND_COLORS = ['#729fcf', '#ea9999', '#f9cb9c', '#cccccc']

# L2 Style: Sequential blues
L2_COMPONENTS = ['wal', 'memtable', 'compaction', 'sstable_lookup']
L2_COLORS = ['#cfe2f3', '#9fc5e8', '#6fa8dc', '#3d85c6']
L2_LEGEND_LABELS = ['WAL', 'MemTable', 'Compaction', 'SSTable lookup']
L2_LEGEND_COLORS = ['#cfe2f3', '#9fc5e8', '#6fa8dc', '#3d85c6']

def extract_json_from_log(log_path):
    """Extract JSON data from log file."""
    with open(log_path, 'r') as f:
        content = f.read()
    pattern = r'={10} COST_STATS_JSON ={10}\s*(\{.*?\})\s*={37}'
    match = re.search(pattern, content, re.DOTALL)
    if not match: return None
    try: return json.loads(match.group(1))
    except: return None

def plot_stacked_bar(ax, data, components, colors, legend_labels, legend_colors, title):
    """Plot a stacked bar chart with reference styling."""
    x = np.arange(len(data))
    width = 0.55
    bottom = np.zeros(len(data))
    
    # Enable horizontal grid lines behind bars
    ax.yaxis.grid(True, linestyle='-', linewidth=0.5, color='#e0e0e0', zorder=0)
    
    # Prepare bars
    rects_list = []
    for i, (comp, color) in enumerate(zip(components, colors)):
        values = [d.get(comp, 0) for d in data.values()]
        bars = ax.bar(x, values, width, bottom=bottom, color=color, zorder=3, edgecolor='none')
        
        # Add percentage labels
        for j, (bar, val) in enumerate(zip(bars, values)):
            if val >= 1.5:  # Show labels even for small slices like '2%'
                # Use white text for dark blue, black for others
                txt_color = 'white' if color in ['#3d85c6', '#6fa8dc'] else '#333333'
                ax.text(bar.get_x() + bar.get_width()/2, bottom[j] + val/2,
                       f'{val:.0f}%', ha='center', va='center', 
                       fontsize=10, fontweight='medium', color=txt_color, zorder=4)
        bottom += values

    # Styling axes
    ax.set_xticks(x)
    ax.set_xticklabels(list(data.keys()), fontsize=11)
    ax.set_ylim(0, 100)
    ax.set_yticks([]) # Hide Y axis ticks
    
    # Remove top, left, and right spines
    for spine in ['top', 'left', 'right']:
        ax.spines[spine].set_visible(False)
    ax.spines['bottom'].set_color('#333333')

    # Custom Legend (2 rows, matching image order)
    from matplotlib.lines import Line2D
    legend_elements = [Line2D([0], [0], color=c, lw=8, label=l, marker='s', markersize=8, linestyle='None') 
                       for l, c in zip(legend_labels, legend_colors)]
    ax.legend(handles=legend_elements, loc='upper center', bbox_to_anchor=(0.5, 1.3),
              ncol=2, frameon=False, fontsize=10, handletextpad=0.5, columnspacing=1.0)

    # Title at bottom
    ax.text(0.5, -0.3, title, transform=ax.transAxes, fontsize=14, 
            ha='center', va='center', fontweight='bold')

def main():
    results_dir = Path(__file__).parent / 'results'
    if not results_dir.exists():
        print(f"Error: Results directory not found: {results_dir}")
        sys.exit(1)
    
    l3_data, l2_data = {}, {}
    for test_name, label in TESTS.items():
        log_path = results_dir / f'{test_name}.log'
        data = extract_json_from_log(log_path) if log_path.exists() else None
        if data:
            l3_data[label] = data.get('L3', {})
            l2_data[label] = data.get('L2', {})

    if not l3_data:
        print("Error: No valid data found.")
        sys.exit(1)

    # Set up figure
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.5))

    plot_stacked_bar(ax1, l3_data, L3_COMPONENTS, L3_COLORS, 
                     L3_LEGEND_LABELS, L3_LEGEND_COLORS, '(a) Cost breakdown in L3')
    
    plot_stacked_bar(ax2, l2_data, L2_COMPONENTS, L2_COLORS, 
                     L2_LEGEND_LABELS, L2_LEGEND_COLORS, '(b) Cost breakdown in L2')

    plt.subplots_adjust(top=0.75, bottom=0.22, wspace=0.15)
    
    output_path = 'result.png'
    plt.savefig(output_path, dpi=200, bbox_inches='tight')
    print(f"Refined chart saved to: {output_path}")
    plt.show()

if __name__ == '__main__':
    main()
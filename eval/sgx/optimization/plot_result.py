import matplotlib.pyplot as plt
import numpy as np
import json
import os

# 1. Load data from the JSON file
file_path = './results/optimization_results.json'

try:
    with open(file_path, 'r') as f:
        data = json.load(f)
except FileNotFoundError:
    print(f"Error: The file {file_path} was not found.")
    # Fallback dummy data for demonstration if file is missing
    data = []

# 2. Extract values dynamically based on labels
# We use next() with a generator to find the specific entry for each category
write_base = next(d['throughput_mib_s'] for d in data if d['type'] == 'write' and not d['delayed_reclamation'])
write_opt  = next(d['throughput_mib_s'] for d in data if d['type'] == 'write' and d['delayed_reclamation'])
read_base  = next(d['throughput_mib_s'] for d in data if d['type'] == 'read' and not d['two_level_caching'])
read_opt   = next(d['throughput_mib_s'] for d in data if d['type'] == 'read' and d['two_level_caching'])

write_values = [write_base, write_opt]
read_values = [read_base, read_opt]

# 3. Setup Plotting Parameters
labels = ['Write\nbaseline', 'Delayed\nreclamation', 'Read\nbaseline', 'Two-level\ncaching']
x_pos = np.arange(len(labels))
colors = ['#e1edf9', '#5072bc', '#d2e8ca', '#7db86e'] # Light Blue, Dark Blue, Light Green, Dark Green

fig, ax1 = plt.subplots(figsize=(10, 5))

# --- Plot Write Section (Left Y-axis) ---
ax1.bar(x_pos[:2], write_values, color=colors[:2], edgecolor='black', linewidth=2, width=0.7)
ax1.set_ylabel('Throughput (MiB/S)', fontsize=16, fontweight='bold')
# Set Y-limit dynamically (15% headroom)
ax1.set_ylim(0, max(write_values) * 1.15)
ax1.tick_params(axis='y', labelsize=14)

# --- Plot Read Section (Right Y-axis) ---
ax2 = ax1.twinx()
ax2.bar(x_pos[2:], read_values, color=colors[2:], edgecolor='black', linewidth=2, width=0.7)
# Set Y-limit dynamically (15% headroom)
ax2.set_ylim(0, max(read_values) * 1.15)
ax2.tick_params(axis='y', labelsize=14)

# --- Layout and Styling ---
ax1.set_xticks(x_pos)
ax1.set_xticklabels(labels, fontsize=14)

# Add vertical divider
ax1.axvline(x=1.5, color='black', linestyle='--', linewidth=1.5)

# Add section headers
ax1.text(0.5, ax1.get_ylim()[1] * 0.9, 'Write', fontsize=18, ha='center')
ax2.text(2.5, ax2.get_ylim()[1] * 0.9, 'Read', fontsize=18, ha='center')

# Grid and Spines styling
ax1.yaxis.grid(True, linestyle='-', alpha=0.3)
ax1.set_axisbelow(True)
ax1.spines['top'].set_visible(False)
ax2.spines['top'].set_visible(False)

plt.tight_layout()
plt.savefig('result.png', dpi=300)
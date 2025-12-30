import pandas as pd
import matplotlib.pyplot as plt
import os

# 1. Load data
file_path = './results/reproduce_results.csv'

if not os.path.exists(file_path):
    print(f"Error: {file_path} not found.")
    exit(1)

df = pd.read_csv(file_path)

# Separate data by disk type
sworn_data = df[df['disk_type'] == 'sworndisk'].copy()
crypt_data = df[df['disk_type'] == 'cryptdisk'].copy()

# Ensure numeric types
sworn_data['throughput_mib_s'] = pd.to_numeric(sworn_data['throughput_mib_s'])
sworn_data['waf'] = pd.to_numeric(sworn_data['waf'])
crypt_data['throughput_mib_s'] = pd.to_numeric(crypt_data['throughput_mib_s'])

# As per your instruction: CryptDisk WAF is fixed at 1.04
crypt_waf_fixed = [1.004] * len(crypt_data)

# 2. Plotting Configuration
plt.rcParams['font.family'] = 'sans-serif'
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

# Style constants
marker_size = 6
line_width = 1.5
crypt_color = '#e44132' # Red
sworn_color = '#3b75af' # Blue

# --- Plot (a) Write Amplification Factor ---
# StrataDisk (Blue Triangle)
ax1.plot(sworn_data['fill_percent'], sworn_data['waf'],
         label='StrataDisk', color=sworn_color, marker='^', markersize=marker_size, linewidth=line_width)
# CryptDisk (Red Circle)
ax1.plot(crypt_data['fill_percent'], crypt_waf_fixed, 
         label='CryptDisk', color=crypt_color, marker='o', markersize=marker_size, linewidth=line_width)

ax1.set_ylabel('Write Amp. Factor', fontsize=14, fontweight='bold')
ax1.set_ylim(0.90, 1.15)
ax1.set_yticks([0.90, 0.95, 1.00, 1.05, 1.10, 1.15])

# --- Plot (b) Throughput ---
# StrataDisk (Blue Triangle)
ax2.plot(sworn_data['fill_percent'], sworn_data['throughput_mib_s'],
         label='StrataDisk', color=sworn_color, marker='^', markersize=marker_size, linewidth=line_width)
# CryptDisk (Red Circle)
ax2.plot(crypt_data['fill_percent'], crypt_data['throughput_mib_s'], 
         label='CryptDisk', color=crypt_color, marker='o', markersize=marker_size, linewidth=line_width)

ax2.set_ylabel('Throughput (MB/s)', fontsize=14, fontweight='bold')
ax2.set_ylim(0, 500)

# --- Common Formatting for both Subplots ---
for ax, title in zip([ax1, ax2], ['(a) Write amplification factor', '(b) Throughput']):
    ax.set_xlabel('Disk utility', fontsize=13)
    
    # Set X-axis ticks and labels (e.g., 10%, 30%, ...)
    ax.set_xticks([10, 30, 50, 70, 90])
    ax.set_xticklabels(['10%', '30%', '50%', '70%', '90%'], fontsize=12)
    ax.tick_params(axis='y', labelsize=12)
    
    # Legend at the top (reversed order to match image: CryptDisk first)
    handles, labels = ax.get_legend_handles_labels()
    ax.legend(handles[::-1], labels[::-1], loc='upper center', bbox_to_anchor=(0.5, 1.15),
              ncol=2, frameon=False, fontsize=12, handletextpad=0.1, columnspacing=1.0)
    
    # Horizontal grid lines
    ax.yaxis.grid(True, linestyle='-', alpha=0.3)
    ax.set_axisbelow(True)
    
    # Add title/label at the very bottom
    ax.text(0.5, -0.3, title, transform=ax.transAxes, fontsize=16, 
            ha='center', va='center', fontweight='bold')

# Adjust layout to make room for labels and legends
plt.subplots_adjust(top=0.8, bottom=0.25, wspace=0.3)

# 3. Save the result
output_filename = 'result.png'
plt.savefig(output_filename, dpi=300, bbox_inches='tight')
print(f"Chart successfully saved as: {os.path.abspath(output_filename)}")

# Optional: Show plot
# plt.show()
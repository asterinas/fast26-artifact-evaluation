#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator

def load_throughput(path: Path):
    """Load throughput values from CSV file (one value per line)."""
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as f:
        # Assuming headerless CSV or skipping header if conversion fails
        values = []
        for line in f:
            clean_line = line.strip()
            if not clean_line:
                continue
            try:
                values.append(float(clean_line))
            except ValueError:
                continue # Skip header or malformed lines
    return values

def plot_cleaning_results(results_dir: Path, out_path: Path):
    """Plot throughput over rounds for different configurations."""

    # Define configurations to plot matching the reference image style
    # Format: (filename, label, color, marker)
    # Colors approximated from the image:
    # Cleaning disabled: Dark Blue, Triangle Up
    # Interval 90s: Dark Red, Square
    # Interval 60s: Golden Yellow, Circle
    # Interval 30s: Teal/Light Blue, Diamond
    configs = [
        ("throughput_gc_off.csv", "Cleaning disabled", "#1f4e79", "^"),
        ("throughput_interval_90.csv", "Interval: 90s", "#c0392b", "s"),
        ("throughput_interval_60.csv", "Interval: 60s", "#f1c40f", "o"),
        ("throughput_interval_30.csv", "Interval: 30s", "#76d7c4", "d"),
    ]

    # Create figure with specific aspect ratio
    fig, ax = plt.subplots(figsize=(8, 4.5))

    max_rounds = 0
    
    for filename, label, color, marker in configs:
        filepath = results_dir / filename
        values = load_throughput(filepath)
        
        if values is None:
            # For demonstration if file missing, generate dummy data or skip
            # print(f"Warning: {filepath} not found, skipping")
            continue

        # Adjust X-axis to start from 1 instead of 0
        rounds = [i + 1 for i in range(len(values))]
        max_rounds = max(max_rounds, len(values))
        
        ax.plot(rounds, values, label=label, color=color, marker=marker,
                linewidth=2, markersize=7, markeredgewidth=1)

    # --- Styling to match reference image ---

    # Labels
    ax.set_xlabel('Runs', fontsize=14, fontweight='normal')
    ax.set_ylabel('Throughput (MB/s)', fontsize=14, fontweight='normal')
    
    # Title (Optional: usually removed for paper figures, keeping generic if needed)
    # ax.set_title('', fontsize=16) 

    # Axis Limits & Ticks
    if max_rounds > 0:
        ax.set_xlim(0.5, max_rounds + 0.5)
        ax.xaxis.set_major_locator(MultipleLocator(1)) # Ensure integer ticks
    
    # Set Y-axis range from 100 to 500 based on the image
    ax.set_ylim(100, 500)
    ax.yaxis.set_major_locator(MultipleLocator(100)) # Ticks every 100 unit

    # Tick Parameters
    ax.tick_params(axis='both', which='major', labelsize=12)

    # Grid (Horizontal only, light gray)
    ax.yaxis.grid(True, linestyle='-', alpha=0.3, color='lightgray')
    ax.xaxis.grid(False) # No vertical grid
    ax.set_axisbelow(True) # Grid behind plot lines

    # Legend (Top, horizontal, no frame)
    ax.legend(
        loc='lower center', 
        bbox_to_anchor=(0.5, 1.02), # Position above the plot
        ncol=4, # 4 columns to make it horizontal
        fontsize=11, 
        frameon=False, # Remove box around legend
        handletextpad=0.2, # Reduce space between marker and text
        columnspacing=1.0  # Adjust space between legend items
    )

    # Borders (Spines) - Keep them all visible like a box
    for spine in ax.spines.values():
        spine.set_linewidth(0.8)
        spine.set_color('black')

    plt.tight_layout()
    
    # Create output directory if it doesn't exist
    out_path.parent.mkdir(parents=True, exist_ok=True)
    
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
        # Print stack trace for debugging
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
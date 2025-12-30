#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np

def load_results(path: Path):
    """Load results from benchmark JSON file."""
    if not path.exists():
        raise FileNotFoundError(f"Result file not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    # Only map sworndisk and cryptdisk
    disk_type_map = {
        "sworndisk": "SwornDisk",
        "cryptdisk": "CryptDisk"
    }

    test_map = {
        "seq_write_256k": ("Seq.", "write"),
        "rand_write_4k": ("Rnd.\n4KB", "write"),
        "rand_write_32k": ("Rnd.\n32KB", "write"),
        "rand_write_256k": ("Rnd.\n256KB", "write"),
        "seq_read_256k": ("Seq.", "read"),
        "rand_read_4k": ("Rnd.\n4KB", "read"),
        "rand_read_32k": ("Rnd.\n32KB", "read"),
        "rand_read_256k": ("Rnd.\n256KB", "read"),
    }

    results = {}
    for entry in data:
        disk_type = entry.get("disk_type", "")
        if disk_type not in disk_type_map:
            continue
        mapped_disk = disk_type_map[disk_type]

        for test_key, (test_name, test_type) in test_map.items():
            if test_key not in entry:
                continue
            value = float(entry[test_key])
            key = (test_type, test_name)
            if key not in results:
                results[key] = {}
            results[key][mapped_disk] = value

    return results

def plot_disk_comparison(ax, results, disk_types, colors, hatches, title):
    """Plot comparison with exact visual style from the reference image."""
    test_order = ["Seq.", "Rnd.\n4KB", "Rnd.\n32KB", "Rnd.\n256KB"]
    test_names = [t for t in test_order if any(k[1] == t for k in results.keys())]

    x = np.arange(len(test_names))
    width = 0.35  # Wider bars since we only have 2 disk types

    # Plot each disk type
    for i, (disk, color, hatch) in enumerate(zip(disk_types, colors, hatches)):
        vals = []
        for name in test_names:
            # Find the specific test value
            val = 0
            for k, v in results.items():
                if k[1] == name:
                    val = v.get(disk, 0)
                    break
            vals.append(val)

        offset = (i - 0.5) * (width + 0.05)  # Center the bars
        # Using white facecolor and colored edges/hatches to match the image style
        ax.bar(x + offset, vals, width, label=disk,
               color='white', edgecolor=color, hatch=hatch, linewidth=1.5)

    # Styling
    ax.set_ylabel('Throughput (MB/s)', fontsize=16)
    ax.set_xticks(x)
    ax.set_xticklabels(test_names, fontsize=15)
    ax.tick_params(axis='y', labelsize=14)

    # Y-axis limit and grid
    ax.set_ylim(0, 1000)
    ax.set_yticks([0, 200, 400, 600, 800, 1000])
    ax.yaxis.grid(True, linestyle='-', alpha=0.3)
    ax.set_axisbelow(True)

    # Remove top and right spines
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)

    # Title at the bottom
    ax.text(0.5, -0.25, title, transform=ax.transAxes,
            fontsize=18, fontweight='bold', ha='center')

    # Legend at the top
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, 1.0),
              ncol=2, frameon=False, fontsize=13, handletextpad=0.3, columnspacing=0.8)

def plot_grouped_bars(results, out_path: Path):
    # Separate write and read
    write_res = {k: v for k, v in results.items() if k[0] == "write"}
    read_res = {k: v for k, v in results.items() if k[0] == "read"}

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Only 2 disk types: CryptDisk and SwornDisk
    # CryptDisk: Red/Vertical, SwornDisk: Blue/Diagonal
    disk_types = ["CryptDisk", "SwornDisk"]
    colors = ["#e74c3c", "#4a90e2"]
    hatches = ["||||", "////"]

    plot_disk_comparison(ax1, write_res, disk_types, colors, hatches, "(a) Writes in SEV")
    plot_disk_comparison(ax2, read_res, disk_types, colors, hatches, "(b) Reads in SEV")

    plt.tight_layout()
    plt.subplots_adjust(bottom=0.22) # Make room for bottom titles

    plt.savefig(out_path, dpi=300, bbox_inches='tight')
    print(f"Chart successfully saved to {out_path}")

def main():
    parser = argparse.ArgumentParser(description="Plot FIO benchmark results for SwornDisk and CryptDisk")
    parser.add_argument("--input", default="benchmark_results/result.json", type=Path,
                        help="Input JSON file with benchmark results")
    parser.add_argument("--output", default="result.png", type=Path,
                        help="Output PNG file for the chart")
    args = parser.parse_args()

    try:
        results = load_results(args.input)
        if not results:
            print("Warning: No valid results found in input file")
            sys.exit(1)
        plot_grouped_bars(results, args.output)
    except Exception as e:
        sys.stderr.write(f"Error: {e}\n")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()

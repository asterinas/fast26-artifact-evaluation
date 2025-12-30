#!/bin/bash
# Analyze MSR trace files ending with _0
# Statistics:
# 1. Total read/write volume in GiB
# 2. Read miss rate (reads to blocks that were never written before)

set -e

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
TRACE_DIR="${SCRIPT_DIR}/msr-test"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Block size for tracking (4KB)
BLOCK_SIZE=4096

analyze_trace() {
    local trace_file=$1
    local trace_name=$(basename "$trace_file" .csv)
    
    echo -e "${YELLOW}Analyzing ${trace_name}...${NC}"
    
    # Use awk to analyze the trace
    # Format: Timestamp,Hostname,DiskNumber,Type,Offset,Size,ResponseTime
    awk -F',' -v block_size="$BLOCK_SIZE" '
    BEGIN {
        read_bytes = 0
        write_bytes = 0
        read_miss = 0
        read_hit = 0
        total_reads = 0
    }
    {
        type = $4
        offset = $5
        size = $6
        
        if (type == "Read") {
            read_bytes += size
            total_reads++
            
            # Calculate block range
            start_block = int(offset / block_size)
            end_block = int((offset + size - 1) / block_size)
            
            # Check if any block in this read was not written before
            miss = 0
            for (b = start_block; b <= end_block; b++) {
                if (!(b in written_blocks)) {
                    miss = 1
                    break
                }
            }
            if (miss) {
                read_miss++
            } else {
                read_hit++
            }
        } else if (type == "Write") {
            write_bytes += size
            
            # Mark blocks as written
            start_block = int(offset / block_size)
            end_block = int((offset + size - 1) / block_size)
            for (b = start_block; b <= end_block; b++) {
                written_blocks[b] = 1
            }
        }
    }
    END {
        gib = 1024 * 1024 * 1024
        read_gib = read_bytes / gib
        write_gib = write_bytes / gib
        
        if (total_reads > 0) {
            miss_rate = (read_miss / total_reads) * 100
        } else {
            miss_rate = 0
        }
        
        printf "  Read:       %.3f GiB\n", read_gib
        printf "  Write:      %.3f GiB\n", write_gib
        printf "  Total:      %.3f GiB\n", read_gib + write_gib
        printf "  Read Ops:   %d (hit: %d, miss: %d)\n", total_reads, read_hit, read_miss
        printf "  Miss Rate:  %.2f%%\n", miss_rate
    }
    ' "$trace_file"
    
    echo ""
}

main() {
    echo -e "${GREEN}=== MSR Trace Analysis (files ending with _0) ===${NC}\n"
    
    # Find all _0.csv files
    for trace_file in "${TRACE_DIR}"/*_0.csv; do
        if [ -f "$trace_file" ]; then
            analyze_trace "$trace_file"
        fi
    done
    
    # Also check for gzipped files
    for trace_file in "${TRACE_DIR}"/*_0.csv.gz; do
        if [ -f "$trace_file" ]; then
            trace_name=$(basename "$trace_file" .csv.gz)
            echo -e "${YELLOW}Analyzing ${trace_name} (gzipped)...${NC}"
            zcat "$trace_file" | awk -F',' -v block_size="$BLOCK_SIZE" '
            BEGIN {
                read_bytes = 0; write_bytes = 0; read_miss = 0; read_hit = 0; total_reads = 0
            }
            {
                type = $4; offset = $5; size = $6
                if (type == "Read") {
                    read_bytes += size; total_reads++
                    start_block = int(offset / block_size)
                    end_block = int((offset + size - 1) / block_size)
                    miss = 0
                    for (b = start_block; b <= end_block; b++) {
                        if (!(b in written_blocks)) { miss = 1; break }
                    }
                    if (miss) read_miss++; else read_hit++
                } else if (type == "Write") {
                    write_bytes += size
                    start_block = int(offset / block_size)
                    end_block = int((offset + size - 1) / block_size)
                    for (b = start_block; b <= end_block; b++) written_blocks[b] = 1
                }
            }
            END {
                gib = 1024 * 1024 * 1024
                printf "  Read:       %.3f GiB\n", read_bytes / gib
                printf "  Write:      %.3f GiB\n", write_bytes / gib
                printf "  Total:      %.3f GiB\n", (read_bytes + write_bytes) / gib
                printf "  Read Ops:   %d (hit: %d, miss: %d)\n", total_reads, read_hit, read_miss
                if (total_reads > 0) printf "  Miss Rate:  %.2f%%\n", (read_miss / total_reads) * 100
            }'
            echo ""
        fi
    done
}

main "$@"


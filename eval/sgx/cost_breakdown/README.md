# Cost Breakdown

Collects L2/L3 cost statistics for sequential and random I/O patterns on StrataDisk.

Tests:
- Sequential Write/Read (128KB blocks)
- Random Write/Read (4KB blocks)

## Prerequisites

FIO must be built first:
```bash
cd ../fio && ./download_and_build_fio.sh
```

## Run

```bash
./reproduce.sh
```

## Plot

```bash
python3 plot_result.py
```

## Output

- Raw logs with cost stats: `results/{seq|rand}-{read|write}.log`
- Plot: `result.png`

### Cost Statistics

Each log contains L2/L3 breakdown:
- **L3**: Logical Block Table, Block I/O, Encryption, Allocation
- **L2**: WAL, MemTable, Compaction, SSTable Lookup

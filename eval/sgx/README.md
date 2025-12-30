# Evaluation on SGX

Benchmarks for running the storage stack inside SGX (Occlum).

## Overview
1. **FIO** — Micro-benchmarks on block devices.
2. **Trace-driven** — MSR Cambridge trace replay.
3. **Filebench** — Filesystem workloads (File Server, OLTP, Varmail, Video Server).
4. **Cache Size** — Read/write sensitivity to cache size.
5. **Disk Utility (Aging)** — Throughput/WAF vs. fill level.
6. **Cleaning** — GC interval and overhead.
7. **Optimization** — StrataDisk toggles: `delayed_reclamation`, `two_level_caching`.
8. **Cost Breakdown** — L2/L3 cost stats for seq/rand IO.

## Environment
**Note**: All evaluations should run inside a Docker conatiner:
- SGX-enabled host with `/dev/sgx_enclave` and `/dev/sgx_provision`.
- Occlum 0.31.0-rc build:
  ```bash
  sudo docker pull occlum/occlum:0.31.0-rc-ubuntu22.04
  git clone https://github.com/Fischer0522/occlum.git -b fast26_ae {occlum_src_path}
  sudo docker run -it --device /dev/sgx_enclave --device /dev/sgx_provision --name "ae-occlum-0.31.0-rc-dev" --net=host -v "{occlum_src_path}:/root/occlum" occlum/occlum:0.31.0-rc-ubuntu22.04
  git config --global --add safe.directory '*'

  # Inside container
  cd /root/occlum
  make submodule
  OCCLUM_RELEASE_BUILD=1 make install
  ```
- Dependencies such as FIO/Filebench are auto-built by the scripts when absent.

## Benchmarks (directory guide)

**Note**:
- The evaluation scripts (corresponding to eval/sgx in the repo) are already located at /root/occlum/eval inside the container after launching the container. You can navigate there and run the tests directly
- Each benchmark directory ships `reproduce.sh` (runs the workloads) and `plot_result.py` (turns logs into figures).
- Cache size, disk utility, optimization, and cost breakdown benchmarks rely on `fio` being built first.

### FIO/ — Micro-benchmarks
- What: Seq/rand read/write on PfsDisk/SwornDisk/CryptDisk (per config).
- Prep: `cd fio && ./download_and_build_fio.sh`
- Run: `./reproduce.sh`
- Output: `results/reproduce_result.json`, per-test logs; plot via `python3 plot_result.py` (`result.png`).

### Trace/ — MSR trace replay
- Traces: `hm_0`, `mds_0`, `prn_0`, `wdev_0`, `web_0`.
 - Prep: `cd trace`; if traces are missing, download from [MSR-Trace](https://iotta.snia.org/traces/block-io/388), unzip them, and place all trace files under `msr-test/`.
- Run all: `./reproduce.sh` (builds Occlum instances, runs all disks/traces).
- Output: `results/trace_reproduce_result.json` plus per-trace logs; plot with `python3 plot_result.py`.

### Filebench/ — Filesystem workloads
- Workloads: `fileserver`, `oltp`, `varmail`, `videoserver`.
- Prep: `cd filebench && ./preinstall_deps.sh && ./dl_and_build_filebench.sh`.
- Run all: `./reproduce.sh`.
- Output: logs/JSON under `results/`; plot with `python3 plot_result.py`.

### Cache Size/ — Cache size sensitivity
- What: 4K randwrite/randread vs. cache size for `sworndisk` and `cryptdisk`.
- Run: `cd cache_size && ./reproduce.sh`
- Output: `results/cache_size_result.json` and raw FIO logs; plot with `python3 plot_result.py`.

### Disk Utility/ — Disk aging & utilization
- What: Throughput and WAF as disk fills from 10% to 90% (fresh Occlum per level).
- Run: `./reproduce.sh`
- Output: `results/disk_age_results.csv` and `disk_age_results.json`; plot via `python3 plot_result.py`.

### Cleaning/ — Cleaning interval impact
- What: Prefill then batched writes with sleep intervals; GC toggles.
- Run: `cd cleaning && ./reproduce.sh`
- Output: logs in `results/`; plot via `python3 plot_result.py`.

### Optimization/ — MlsDisk feature toggles
- What: `delayed_reclamation` (rand write) and `two_level_caching` (rand read).
- Run: `cd optimization && ./reproduce.sh`
- Output: `results/optimization_results.json` plus logs; plot with `python3 plot_result.py`.

### Cost Breakdown/ — L2/L3 cost statistics
- What: Seq/rand read/write with `stat_cost=true`.
- Run: `cd cost_breakdown && ./reproduce.sh` (needs `../fio` built).
- Output: logs in `results/`; visualize stacks with `python3 plot_result.py` (`result.png`).

## Result Analysis
- Every benchmark folder has `plot_result.py`; run after workloads to emit figures next to the logs.
- JSON summaries live beside the logs (`results/`) for custom analysis.


Paper figure mapping:
- FIO → Figure 10 (a, b)
- Trace → Figure 11 (a)
- Filebench → Figure 12 (a)
- Cache Size → Figure 14 (a, b)
- Disk Utility → Figure 15 (a, b)
- Cleaning → Figure 16
- Optimization → Figure 18
- Cost Breakdown → Figure 17
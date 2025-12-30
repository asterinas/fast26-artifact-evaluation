# 11.2 Micro Benchmarks

This project demonstrates how Occlum enables the [Flexible I/O Tester(FIO)](https://github.com/axboe/fio) in SGX enclaves.


Step 1: Download and build the FIO

NOTE: In the machine we provided, fio has been alreadw downloaded and built. So you can find fio in ./fio_src. You can skip this step.
```
./download_and_build_fio.sh
```
When completed, the FIO program is generated in the source directory of it.

Step 2: Run the FIO program to test three disk types (PfsDisk, StrataDisk, CryptDisk) inside SGX enclave with Occlum
```
./reproduce.sh
```
When completed, the results are saved in the `benchmark_results` directory. The results are in JSON format and can be plotted with `plot_results.py`. The script requires `matplotlib` and `numpy` to be installed. To install the dependencies, run:

```
pip3 install -r requirements.txt
```

Step 3: Plot the results
```
python3 plot_results.py
```

When completed, the plot is saved in as `result.png` in the current directory.

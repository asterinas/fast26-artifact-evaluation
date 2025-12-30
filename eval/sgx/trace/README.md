## Run MSR trace on Occlum

### Step 1: Prepare docker image and build Occlum
```
sudo docker pull occlum/occlum:0.31.0-rc-ubuntu22.04

git clone https://github.com/lucassong-mh/occlum.git -b dev-atomicdisk-fast25 {occlum_src_path}

sudo docker run -it --device /dev/sgx/enclave --device /dev/sgx/provision --name "ssw-occlum-0.31.0-rc-dev" --net=host -v "{occlum_src_path}:/root/occlum" occlum/occlum:0.31.0-rc-ubuntu22.04

git config --global --add safe.directory /root/occlum  // And other dependent repos

// Inside container
cd /root/occlum
make submodule
OCCLUM_RELEASE_BUILD=1 make install
```

### Step 2: Download trace to msr-test/

### Step 3: Run trace workloads
```
cd demos/benchmarks/trace && ./run_trace_bench.sh wdev
./run_trace_bench.sh hm
```

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <random>
#include <string>
#include <thread>
#include <unistd.h>

using namespace std;

const long long KiB = 1024LL;
const long long MiB = KiB * 1024LL;
const long long GiB = MiB * 1024LL;
const size_t kBlockSize = 4 * KiB; // keep 4KiB alignment for O_DIRECT

struct Options {
    string disk_path = "/dev/sworndisk";
    long long total_bytes = 100LL * GiB;
    long long batch_bytes = 10LL * GiB;
    double used_rate = 0.8; // how much to prefill before rounds
    int interval_sec = 90;
    int loop_times = 11;
};

static long long align_down(long long value) {
    return (value / (long long)kBlockSize) * (long long)kBlockSize;
}

static void parse_args(int argc, char **argv, Options &opt) {
    if (argc > 1 && argv[1]) {
        opt.disk_path = argv[1];
    }
    if (argc > 2 && argv[2]) {
        opt.total_bytes = atoll(argv[2]) * GiB;
    }
    if (argc > 3 && argv[3]) {
        opt.batch_bytes = atoll(argv[3]) * GiB;
    }
    if (argc > 4 && argv[4]) {
        opt.used_rate = atof(argv[4]);
    }
    if (argc > 5 && argv[5]) {
        opt.interval_sec = atoi(argv[5]);
    }
    if (argc > 6 && argv[6]) {
        opt.loop_times = atoi(argv[6]);
    }
}

static bool write_full(int fd, const void *buf, size_t len, off_t offset) {
    const char *p = static_cast<const char *>(buf);
    size_t written = 0;
    while (written < len) {
        ssize_t n = pwrite(fd, p + written, len - written, offset + written);
        if (n < 0) {
            perror("pwrite");
            return false;
        }
        written += static_cast<size_t>(n);
    }
    return true;
}

static bool prefill_disk(int fd, long long bytes, void *buf) {
    cout << "Prefill: target " << (bytes / MiB) << " MiB" << endl;
    long long written = 0;
    while (written < bytes) {
        if (!write_full(fd, buf, kBlockSize, written)) {
            return false;
        }
        written += kBlockSize;
        if (written % (10 * GiB) == 0) {
            cout << "Prefilled " << (written / GiB) << " GiB" << endl;
        }
    }
    fsync(fd);
    return true;
}

static bool run_rounds(int fd, const Options &opt, void *buf, long long usable_blocks) {
    mt19937_64 rng(chrono::high_resolution_clock::now().time_since_epoch().count());

    long long blocks_per_round = opt.batch_bytes / kBlockSize;
    // Limit random writes to [0, blocks_per_round) to keep reclaimed space concentrated
    uniform_int_distribution<long long> dist(0, blocks_per_round - 1);
    if (blocks_per_round <= 0) {
        cerr << "batch_bytes too small" << endl;
        return false;
    }

    for (int i = 0; i < opt.loop_times; ++i) {
        auto start = chrono::high_resolution_clock::now();
        for (long long b = 0; b < blocks_per_round; ++b) {
            long long blk = dist(rng);
            off_t offset = blk * (off_t)kBlockSize;
            if (!write_full(fd, buf, kBlockSize, offset)) {
                return false;
            }
        }
        fsync(fd);
        auto end = chrono::high_resolution_clock::now();
        double elapsed_sec = chrono::duration_cast<chrono::duration<double>>(end - start).count();
        double throughput = (double)opt.batch_bytes / MiB / elapsed_sec;
        cout << "round[" << i << "] throughput: " << throughput << " MiB/s" << endl;

        if (i + 1 < opt.loop_times) {
            this_thread::sleep_for(chrono::seconds(opt.interval_sec));
        }
    }
    return true;
}

int main(int argc, char *argv[]) {
    Options opt;
    parse_args(argc, argv, opt);

    opt.total_bytes = align_down(opt.total_bytes);
    opt.batch_bytes = align_down(opt.batch_bytes);
    if (opt.total_bytes <= 0 || opt.batch_bytes <= 0) {
        cerr << "total_bytes and batch_bytes must be positive" << endl;
        return -1;
    }

    cout << "Disk: " << opt.disk_path << endl;
    cout << "Total: " << (opt.total_bytes / GiB) << " GiB, Batch: "
         << (opt.batch_bytes / GiB) << " GiB, Used rate: " << opt.used_rate
         << ", Interval: " << opt.interval_sec << "s, Loops: " << opt.loop_times << endl;

    int fd = open(opt.disk_path.c_str(), O_RDWR | O_CREAT | O_DIRECT, 0666);
    if (fd < 0) {
        perror("open");
        return -1;
    }

    // if (ftruncate(fd, opt.total_bytes) < 0) {
    //     perror("ftruncate");
    //     close(fd);
    //     return -1;
    // }

    void *buf = nullptr;
    if (posix_memalign(&buf, kBlockSize, kBlockSize) != 0) {
        cerr << "posix_memalign failed" << endl;
        close(fd);
        return -1;
    }
    memset(buf, 0x5a, kBlockSize);

    long long prefill_bytes = align_down(static_cast<long long>(opt.total_bytes * opt.used_rate));
    if (prefill_bytes < kBlockSize) {
        prefill_bytes = kBlockSize;
    }

    if (!prefill_disk(fd, prefill_bytes, buf)) {
        free(buf);
        close(fd);
        return -1;
    }

    long long usable_blocks = prefill_bytes / kBlockSize;
    if (usable_blocks <= 0) {
        cerr << "No usable blocks for rounds" << endl;
        free(buf);
        close(fd);
        return -1;
    }

    bool ok = run_rounds(fd, opt, buf, usable_blocks);

    free(buf);
    close(fd);
    return ok ? 0 : -1;
}

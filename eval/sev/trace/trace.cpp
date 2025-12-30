#define _GNU_SOURCE // 必须定义，以启用 O_DIRECT
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>
#include <stdlib.h>
#include <iostream>
#include <chrono>
#include <vector>
#include <string>
#include <algorithm>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

const long long KiB = 1024;
const long long MiB = KiB * 1024;
const long long GiB = MiB * 1024;

const int block_size = KiB * 4;
const long long disk_total_size = 50 * GiB;
const long long max_blocks = disk_total_size / block_size;

struct TraceEntry {
    string rw_type;
    long long lba;
    long long rw_size;
};

int main(int argc, char *argv[])
{
    if (argc < 3)
    {
        cout << "Usage: " << argv[0] << " <disk_path> <trace_file>" << endl;
        return -1;
    }

    char *disk_path = argv[1];
    char *trace_file = argv[2];

    // 1. 使用 O_DIRECT 打开文件/设备，绕过 Page Cache 获得真实性能
    // 注意：O_DIRECT 读写要求偏移量和大小必须是扇区对齐的（通常 512B 或 4K）
    int flags = O_RDWR | O_CREAT | O_DIRECT;
    int file = open(disk_path, flags, 0666);
    if (file < 0)
    {
        perror("Open disk failed");
        cout << "Hint: Ensure the filesystem or device supports O_DIRECT." << endl;
        return -1;
    }

    // 2. 检测目标类型
    struct stat st;
    if (fstat(file, &st) < 0) {
        perror("fstat failed");
        return -1;
    }

    if (S_ISBLK(st.st_mode)) {
        cout << "Target is a BLOCK DEVICE. Skipping allocation." << endl;
    } else {
        cout << "Target is a REGULAR FILE. Pre-allocating " << disk_total_size / GiB << " GiB..." << endl;
        // posix_fallocate 比 ftruncate 更好，它会强制分配物理磁盘块
        if (posix_fallocate(file, 0, disk_total_size) != 0) {
            perror("fallocate failed (non-fatal, continuing)");
            ftruncate(file, disk_total_size);
        }
    }

    if (freopen(trace_file, "r", stdin) == nullptr)
    {
        cout << "Open trace file " << trace_file << " failed!" << endl;
        return -1;
    }

    // ============ Phase 1: Parse trace ============
    cout << "Phase 1: Parsing trace file..." << endl;
    vector<TraceEntry> trace_entries;
    
    // 使用 vector<bool> 替代 set，内存占用更小且查找速度快数千倍
    vector<bool> written_blocks_mask(max_blocks, false);
    vector<long long> warmup_blocks_list;

    char line[1000];
    long long parse_cnt = 0;

    while (scanf("%s", line) != EOF)
    {
        string ss = line;
        // 简单的 CSV 解析逻辑 (跳过 Timestamp, Hostname, DiskNumber)
        for(int i=0; i<3; ++i) {
            size_t pos = ss.find(",");
            if(pos == string::npos) break;
            ss = ss.substr(pos + 1);
        }

        size_t pos = ss.find(",");
        string rw_type = ss.substr(0, pos);

        ss = ss.substr(pos + 1);
        pos = ss.find(",");
        long long lba = atoll(ss.substr(0, pos).c_str());

        // LBA & Size 对齐检查 (O_DIRECT 必须要求)
        if (lba % block_size != 0) lba = (lba / block_size) * block_size;
        lba = lba % disk_total_size;

        ss = ss.substr(pos + 1);
        pos = ss.find(",");
        long long rw_size = atoll(ss.substr(0, pos).c_str());
        if (rw_size % block_size != 0) rw_size = ((rw_size / block_size) + 1) * block_size;

        if (lba + rw_size > disk_total_size) lba = disk_total_size - rw_size;

        // 跟踪需要预热的块（即那些在写之前就要被读的块）
        long long start_block = lba / block_size;
        long long num_blocks = rw_size / block_size;

        if (rw_type == "Read") {
            for (long long b = 0; b < num_blocks; b++) {
                long long cur = start_block + b;
                if (cur < max_blocks && !written_blocks_mask[cur]) {
                    warmup_blocks_list.push_back(cur);
                    written_blocks_mask[cur] = true; // 标记已读，防止重复预热
                }
            }
        } else if (rw_type == "Write") {
            for (long long b = 0; b < num_blocks; b++) {
                long long cur = start_block + b;
                if (cur < max_blocks) written_blocks_mask[cur] = true;
            }
        }

        TraceEntry entry;
        entry.rw_type = rw_type;
        entry.lba = lba;
        entry.rw_size = rw_size;
        trace_entries.push_back(entry);

        if (++parse_cnt % 1000000 == 0) cout << "Parsed " << parse_cnt << " lines..." << endl;
    }

    // ============ Phase 2: Warmup ============
    string disk_path_str(disk_path);
    bool is_sworndisk = (disk_path_str.find("sworndisk") != string::npos);

    if (is_sworndisk && !warmup_blocks_list.empty())
    {
        cout << "\nPhase 2: Warmup - writing to " << warmup_blocks_list.size() << " blocks..." << endl;
        void *warmup_buf;
        posix_memalign(&warmup_buf, 4096, block_size);
        memset(warmup_buf, 0, block_size);

        long long warmup_cnt = 0;
        for (long long block : warmup_blocks_list)
        {
            if (pwrite(file, warmup_buf, block_size, block * block_size) != block_size) {
                perror("Warmup pwrite failed");
                break;
            }
            if (++warmup_cnt % 500000 == 0) cout << "Warmup progress: " << warmup_cnt << " blocks..." << endl;
        }
        free(warmup_buf);
        fsync(file);
    }

    // ============ Phase 3: Replay trace ============
    cout << "\nPhase 3: Replaying trace..." << endl;
    
    auto total_start = std::chrono::high_resolution_clock::now();
    long long total_r_size = 0, total_w_size = 0;
    long long total_r_latency = 0, total_w_latency = 0;

    for (size_t i = 0; i < trace_entries.size(); ++i)
    {
        const auto& entry = trace_entries[i];
        void *rw_buf;
        if (posix_memalign(&rw_buf, 4096, entry.rw_size) != 0) return -1;

        auto start = std::chrono::high_resolution_clock::now();
        
        ssize_t ret;
        if (entry.rw_type == "Read") {
            ret = pread(file, rw_buf, entry.rw_size, entry.lba);
            total_r_size += entry.rw_size;
        } else {
            ret = pwrite(file, rw_buf, entry.rw_size, entry.lba);
            total_w_size += entry.rw_size;
        }

        if (ret != (ssize_t)entry.rw_size) {
            perror("Replay I/O failed");
            free(rw_buf);
            break;
        }

        auto end = std::chrono::high_resolution_clock::now();
        auto lat = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        if (entry.rw_type == "Read") total_r_latency += lat;
        else total_w_latency += lat;

        free(rw_buf);

        if ((i + 1) % 500000 == 0) {
            cout << "Processed " << i + 1 << " / " << trace_entries.size() << " requests..." << endl;
        }
    }

    fsync(file);
    close(file);

    auto total_end = std::chrono::high_resolution_clock::now();
    double total_sec = std::chrono::duration_cast<std::chrono::milliseconds>(total_end - total_start).count() / 1000.0;

    cout << "\nTrace Replay Summary:" << endl;
    cout << "--------------------------------" << endl;
    cout << "Total Requests: " << trace_entries.size() << endl;
    cout << "Total Data:     " << (total_r_size + total_w_size) / MiB << " MiB" << endl;
    cout << "Total Time:     " << total_sec << " seconds" << endl;
    cout << "Avg Bandwidth:  " << ((total_r_size + total_w_size) / MiB) / total_sec << " MiB/s" << endl;
    cout << "Read Latency:   " << total_r_latency / 1000.0 << " ms (Total)" << endl;
    cout << "Write Latency:  " << total_w_latency / 1000.0 << " ms (Total)" << endl;

    fclose(stdin);
    return 0;
}
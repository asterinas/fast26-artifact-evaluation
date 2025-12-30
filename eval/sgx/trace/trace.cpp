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
#include <set>

using namespace std;

const long long KiB = 1024;
const long long MiB = KiB * 1024;
const long long GiB = MiB * 1024;

const int block_size = KiB * 4;
// 50 * GiB
const long long disk_total_size = 50 * GiB;

// Structure to hold parsed trace entry
struct TraceEntry {
    string rw_type;
    long long lba;
    long long rw_size;
};

int main(int argc, char *argv[])
{
	// /dev/sworn_disk
	char *disk_path = argv[1];
	// /MSR-Cambridge/*.csv
	string trace_dir = "";
	char *trace_file = argv[2];
	string trace_path = trace_dir.append(trace_file);

	if (disk_path == nullptr || trace_file == nullptr)
	{
		cout << "Wrong input! arg1(disk_path) | arg2(trace_file)" << endl;
		return -1;
	}
	cout << "Disk path: " << disk_path << endl;
	cout << "Trace path: " << trace_path << endl;

	if (freopen(trace_path.c_str(), "r", stdin) == nullptr)
	{
		cout << "Open " << trace_path << " failed!" << endl;
		return -1;
	}

	int file = 0;
	if ((file = open(disk_path, O_RDWR | O_CREAT, 0666 )) < 0)
	{
		cout << "Open " << disk_path << " failed!" << endl;
		return -1;
	}

	if (ftruncate(file, disk_total_size) < 0)
	{
		cout << "Truncate " << disk_path << " failed!" << endl;
		close(file);
		return -1;
	}

	// ============ Phase 1: Parse trace and collect entries ============
	cout << "Phase 1: Parsing trace file..." << endl;
	vector<TraceEntry> trace_entries;
	set<long long> written_blocks;  // Track blocks that have been written
	set<long long> warmup_blocks;   // Blocks that need warmup (read before write)

	char line[1000];
	long long parse_cnt = 0;

	while (scanf("%s", line) != EOF)
	{
		parse_cnt++;
		if (parse_cnt % 1000000 == 0)
		{
			cout << "Parsed " << parse_cnt << " lines..." << endl;
		}

		string ss = line;

		// Skip Timestamp, Hostname, DiskNumber
		int pos = ss.find(",");
		ss = ss.substr(pos + 1, ss.size() - pos);
		pos = ss.find(",");
		ss = ss.substr(pos + 1, ss.size() - pos);
		pos = ss.find(",");
		ss = ss.substr(pos + 1, ss.size() - pos);

		// Type
		pos = ss.find(",");
		string rw_type = ss.substr(0, pos);

		// Offset
		ss = ss.substr(pos + 1, ss.size() - pos);
		pos = ss.find(",");
		long long lba = atoll(ss.substr(0, pos).c_str());
		if (lba % block_size != 0)
		{
			lba = ((lba / block_size) + 1) * block_size;
		}
		lba = lba % disk_total_size;
		if (lba > disk_total_size)
		{
			continue;
		}

		// Size
		ss = ss.substr(pos + 1, ss.size() - pos);
		pos = ss.find(",");
		long long rw_size = atoll(ss.substr(0, pos).c_str());
		if (rw_size % block_size != 0)
		{
			rw_size = ((rw_size / block_size) + 1) * block_size;
		}

		if (lba + rw_size > disk_total_size)
		{
			lba = disk_total_size - rw_size;
		}

		// Track blocks for warmup analysis
		long long start_block = lba / block_size;
		long long end_block = (lba + rw_size - 1) / block_size;

		if (rw_type == "Read")
		{
			// Check if any block in this read was not written before
			for (long long b = start_block; b <= end_block; b++)
			{
				if (written_blocks.find(b) == written_blocks.end())
				{
					warmup_blocks.insert(b);
				}
			}
		}
		else if (rw_type == "Write")
		{
			// Mark blocks as written
			for (long long b = start_block; b <= end_block; b++)
			{
				written_blocks.insert(b);
			}
		}

		// Store entry for replay
		TraceEntry entry;
		entry.rw_type = rw_type;
		entry.lba = lba;
		entry.rw_size = rw_size;
		trace_entries.push_back(entry);
	}

	cout << "Phase 1 complete: " << trace_entries.size() << " entries parsed" << endl;
	cout << "Blocks written in trace: " << written_blocks.size() << endl;
	cout << "Blocks needing warmup: " << warmup_blocks.size() << endl;

	// ============ Phase 2: Warmup - write to blocks that will be read but never written ============
	// Only perform warmup for sworndisk (log-structured disk reads holes directly without IO)
	string disk_path_str(disk_path);
	bool need_warmup = (disk_path_str.find("sworndisk") != string::npos);

	if (need_warmup)
	{
		cout << "\nPhase 2: Warmup - writing to " << warmup_blocks.size() << " blocks..." << endl;
		auto warmup_start = std::chrono::high_resolution_clock::now();

		void *warmup_buf;
		if (posix_memalign(&warmup_buf, 4096, block_size) != 0)
		{
			cout << "posix_memalign failed for warmup buffer" << endl;
			return -1;
		}
		memset(warmup_buf, 0, block_size);

		long long warmup_cnt = 0;
		for (long long block : warmup_blocks)
		{
			long long offset = block * block_size;
			lseek(file, offset, SEEK_SET);
			if (write(file, warmup_buf, block_size) != block_size)
			{
				cout << "Warmup write failed at block " << block << endl;
				free(warmup_buf);
				return -1;
			}
			warmup_cnt++;
			if (warmup_cnt % 100000 == 0)
			{
				cout << "Warmup progress: " << warmup_cnt << "/" << warmup_blocks.size() << " blocks" << endl;
			}
		}
		free(warmup_buf);

		fsync(file);

		auto warmup_end = std::chrono::high_resolution_clock::now();
		auto warmup_elapsed = (std::chrono::duration_cast<std::chrono::milliseconds>(warmup_end - warmup_start)).count();
		cout << "Phase 2 complete: Warmup took " << warmup_elapsed / 1000.0 << " seconds" << endl;
		cout << "Warmup wrote " << (warmup_blocks.size() * block_size / MiB) << " MiB" << endl;
	}
	else
	{
		cout << "\nPhase 2: Skipping warmup (not sworndisk)" << endl;
	}

	// ============ Phase 3: Replay trace ============
	cout << "\nPhase 3: Replaying trace..." << endl;

	long long total_r_size = 0;
	long long total_w_size = 0;
	long long total_r_latency = 0;
	long long total_w_latency = 0;
	long long total_latency = 0;

	long long local_r_size = 0;
	long long local_w_size = 0;
	long long local_r_latency = 0;
	long long local_w_latency = 0;
	long long local_latency = 0;

	long long line_cnt = 0;

	// Replay trace entries
	for (const auto& entry : trace_entries)
	{
		line_cnt++;
		if (line_cnt % 1000000 == 0)
		{
			cout << "Replayed " << line_cnt << " / " << trace_entries.size() << " entries" << endl;
		}

		void *rw_buf;
		if (posix_memalign(&rw_buf, 4096, entry.rw_size) != 0)
		{
			cout << "posix_memalign failed" << endl;
			return -1;
		}

		auto start_time = std::chrono::high_resolution_clock::now();

		lseek(file, entry.lba, SEEK_SET);

		int ret = 0;
		if (entry.rw_type == "Read")
		{
			ret = read(file, rw_buf, entry.rw_size);
			total_r_size += entry.rw_size;
			local_r_size += entry.rw_size;
		}
		else if (entry.rw_type == "Write")
		{
			ret = write(file, rw_buf, entry.rw_size);
			total_w_size += entry.rw_size;
			local_w_size += entry.rw_size;
		}
		else
		{
			cout << "Wrong Read/Write Type! " << entry.rw_type << endl;
			free(rw_buf);
			return -1;
		}

		if (ret != entry.rw_size)
		{
			cout << "Read/Write [size: " << entry.rw_size << ", ret: " << ret << "] error, errno: " << errno << endl;
			free(rw_buf);
			return -1;
		}

		auto end_time = std::chrono::high_resolution_clock::now();
		auto elapsed_time = (std::chrono::duration_cast<std::chrono::microseconds>(end_time - start_time)).count();

		if (entry.rw_type == "Read")
		{
			total_r_latency += elapsed_time;
			local_r_latency += elapsed_time;
		}
		else
		{
			total_w_latency += elapsed_time;
			local_w_latency += elapsed_time;
		}

		if (line_cnt % 100000 == 0)
		{
			cout << "Local Read latency: " << (double)local_r_latency / 1000.0 / 1000.0 << " seconds" << endl;
			cout << "Local Write latency: " << (double)local_w_latency / 1000.0 / 1000.0 << " seconds" << endl;
			local_latency = local_r_latency + local_w_latency;

			double local_r_size_mb = (double)local_r_size / (double)MiB;
			double local_w_size_mb = (double)local_w_size / (double)MiB;
			cout << "Local Read size: " << local_r_size_mb << " MiB, "
				 << "Local Write size: " << local_w_size_mb << " MiB" << endl;
			double local_rw_size_mb = local_r_size_mb + local_w_size_mb;
			cout << "Local size: " << local_rw_size_mb << " MiB" << endl;
			double local_latency_sec = (double)local_latency / 1000.0 / 1000.0;
			cout << "Local latency: " << local_latency_sec << " seconds" << endl;
			cout << "Local bandwidth: " << local_rw_size_mb / local_latency_sec << "MiB/s" << endl;

			local_r_size = 0;
			local_w_size = 0;
			local_r_latency = 0;
			local_w_latency = 0;
			local_latency = 0;
		}
		free(rw_buf);
	}
	cout << "read cost: " << (double)total_r_latency / 1000.0 / 1000.0 << " seconds" << endl;
	cout << "write cost: " << (double)total_w_latency / 1000.0 / 1000.0 << " seconds" << endl;
	total_latency = total_r_latency + total_w_latency;
	cout << "read+write cost: " << (double)total_latency / 1000.0 / 1000.0 << " seconds" << endl;

	auto start_time = std::chrono::high_resolution_clock::now();

	fsync(file);
	// fdatasync(file);
	// sync();
	close(file);

	auto end_time = std::chrono::high_resolution_clock::now();
	auto elapsed_time = (std::chrono::duration_cast<std::chrono::microseconds>(end_time - start_time)).count();
	cout << "fsync+close cost: " << (double)elapsed_time / 1000.0 / 1000.0 << " seconds" << endl;

	//total_latency += elapsed_time;

	cout << "Trace Test Finished! Total lines: " << line_cnt << endl;
	double total_r_size_mb = (double)total_r_size / (double)MiB;
	double total_w_size_mb = (double)total_w_size / (double)MiB;
	cout << "Total Read size: " << total_r_size_mb << " MiB, "
		 << "Total Write size: " << total_w_size_mb << " MiB" << endl;
	double total_rw_size_mb = total_r_size_mb + total_w_size_mb;
	cout << "Total size: " << total_rw_size_mb << " MiB" << endl;
	double total_latency_sec = (double)total_latency / 1000.0 / 1000.0;
	cout << "Total latency: " << total_latency_sec << " seconds" << endl;
	cout << "Bandwidth: " << total_rw_size_mb / total_latency_sec << "MiB/s" << endl;

	fclose(stdin);
	return 0;
}
#include "rocksdb_db.h"
#include "workload.h"
#include "statistics.h"
#include <iostream>
#include <iomanip>
#include <memory>

using namespace ycsb;

void PrintUsage(const char* program) {
    std::cout << "Usage: " << program << " <command> [options]" << std::endl;
    std::cout << "Commands:" << std::endl;
    std::cout << "  load    - Load data into database" << std::endl;
    std::cout << "  run     - Run benchmark workload" << std::endl;
    std::cout << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "  -P <file>    Workload property file (required)" << std::endl;
    std::cout << "  -db <path>   RocksDB database path (default: /tmp/rocksdb-ycsb)" << std::endl;
    std::cout << std::endl;
    std::cout << "Examples:" << std::endl;
    std::cout << "  " << program << " load -P workloads/workloada -db /tmp/testdb" << std::endl;
    std::cout << "  " << program << " run -P workloads/workloada -db /tmp/testdb" << std::endl;
}

void PrintStatistics(const std::string& operation, const Statistics& stats, double elapsed_sec) {
    std::cout << "[" << operation << "] Operations: " << stats.GetCount() << std::endl;
    std::cout << "[" << operation << "] Throughput: "
              << std::fixed << std::setprecision(2)
              << (stats.GetCount() / elapsed_sec) << " ops/sec" << std::endl;
    std::cout << "[" << operation << "] Average Latency: "
              << std::fixed << std::setprecision(2)
              << stats.GetAvgLatency() << " us" << std::endl;
    std::cout << "[" << operation << "] Min Latency: " << stats.GetMinLatency() << " us" << std::endl;
    std::cout << "[" << operation << "] Max Latency: " << stats.GetMaxLatency() << " us" << std::endl;
    std::cout << "[" << operation << "] P50 Latency: "
              << std::fixed << std::setprecision(2)
              << stats.GetPercentileLatency(0.5) << " us" << std::endl;
    std::cout << "[" << operation << "] P95 Latency: "
              << std::fixed << std::setprecision(2)
              << stats.GetPercentileLatency(0.95) << " us" << std::endl;
    std::cout << "[" << operation << "] P99 Latency: "
              << std::fixed << std::setprecision(2)
              << stats.GetPercentileLatency(0.99) << " us" << std::endl;
}

int DoLoad(const std::string& workload_file, const std::string& db_path) {
    std::cout << "========================================" << std::endl;
    std::cout << "Loading data phase" << std::endl;
    std::cout << "========================================" << std::endl;

    Workload workload;
    if (!workload.LoadFromFile(workload_file)) {
        return 1;
    }

    RocksDBDatabase db(db_path);
    if (db.Init() != Status::OK) {
        return 1;
    }

    Statistics stats;
    Timer total_timer;

    std::cout << "Inserting " << workload.GetRecordCount() << " records..." << std::endl;

    for (int i = 0; i < workload.GetRecordCount(); ++i) {
        std::string key = "user" + std::to_string(i);

        Fields fields;
        for (int j = 0; j < workload.GetFieldCount(); ++j) {
            fields[workload.FieldName(j)] = workload.RandomValue();
        }

        Timer op_timer;
        Status s = db.Insert(key, fields);
        stats.Record(op_timer.ElapsedMicros());

        if (s != Status::OK) {
            std::cerr << "Insert failed for key: " << key << std::endl;
        }

        if ((i + 1) % 1000 == 0) {
            std::cout << "Loaded " << (i + 1) << " records..." << std::endl;
        }
    }

    double elapsed = total_timer.ElapsedMicros() / 1000000.0;

    std::cout << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Load phase completed" << std::endl;
    std::cout << "========================================" << std::endl;
    PrintStatistics("INSERT", stats, elapsed);
    std::cout << "Total time: " << std::fixed << std::setprecision(2) << elapsed << " seconds" << std::endl;

    db.Close();
    return 0;
}

int DoRun(const std::string& workload_file, const std::string& db_path) {
    std::cout << "========================================" << std::endl;
    std::cout << "Run phase" << std::endl;
    std::cout << "========================================" << std::endl;

    Workload workload;
    if (!workload.LoadFromFile(workload_file)) {
        return 1;
    }

    RocksDBDatabase db(db_path);
    if (db.Init() != Status::OK) {
        return 1;
    }

    Statistics read_stats, update_stats, insert_stats, scan_stats, rmw_stats;
    Timer total_timer;

    std::cout << "Running " << workload.GetOperationCount() << " operations..." << std::endl;

    for (int i = 0; i < workload.GetOperationCount(); ++i) {
        Workload::Operation op = workload.NextOperation();
        Timer op_timer;

        switch (op) {
        case Workload::Operation::READ: {
            std::string key = workload.NextKeyForRead();
            Fields result;
            db.Read(key, result);
            read_stats.Record(op_timer.ElapsedMicros());
            break;
        }
        case Workload::Operation::UPDATE: {
            std::string key = workload.NextKeyForUpdate();
            Fields fields;
            for (int j = 0; j < workload.GetFieldCount(); ++j) {
                fields[workload.FieldName(j)] = workload.RandomValue();
            }
            db.Update(key, fields);
            update_stats.Record(op_timer.ElapsedMicros());
            break;
        }
        case Workload::Operation::INSERT: {
            std::string key = workload.NextKeyForInsert();
            Fields fields;
            for (int j = 0; j < workload.GetFieldCount(); ++j) {
                fields[workload.FieldName(j)] = workload.RandomValue();
            }
            db.Insert(key, fields);
            insert_stats.Record(op_timer.ElapsedMicros());
            break;
        }
        case Workload::Operation::SCAN: {
            std::string key = workload.NextKeyForScan();
            std::vector<Fields> result;
            db.Scan(key, workload.GetScanLength(), result);
            scan_stats.Record(op_timer.ElapsedMicros());
            break;
        }
        case Workload::Operation::READ_MODIFY_WRITE: {
            std::string key = workload.NextKeyForReadModifyWrite();
            Fields fields;
            for (int j = 0; j < workload.GetFieldCount(); ++j) {
                fields[workload.FieldName(j)] = workload.RandomValue();
            }
            db.ReadModifyWrite(key, fields);
            rmw_stats.Record(op_timer.ElapsedMicros());
            break;
        }
        }

        if ((i + 1) % 1000 == 0) {
            std::cout << "Completed " << (i + 1) << " operations..." << std::endl;
        }
    }

    double elapsed = total_timer.ElapsedMicros() / 1000000.0;

    std::cout << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Run phase completed" << std::endl;
    std::cout << "========================================" << std::endl;

    if (read_stats.GetCount() > 0) {
        PrintStatistics("READ", read_stats, elapsed);
        std::cout << std::endl;
    }
    if (update_stats.GetCount() > 0) {
        PrintStatistics("UPDATE", update_stats, elapsed);
        std::cout << std::endl;
    }
    if (insert_stats.GetCount() > 0) {
        PrintStatistics("INSERT", insert_stats, elapsed);
        std::cout << std::endl;
    }
    if (scan_stats.GetCount() > 0) {
        PrintStatistics("SCAN", scan_stats, elapsed);
        std::cout << std::endl;
    }
    if (rmw_stats.GetCount() > 0) {
        PrintStatistics("READ_MODIFY_WRITE", rmw_stats, elapsed);
        std::cout << std::endl;
    }

    uint64_t total_ops = read_stats.GetCount() + update_stats.GetCount() +
                         insert_stats.GetCount() + scan_stats.GetCount() +
                         rmw_stats.GetCount();
    std::cout << "[OVERALL] Throughput: "
              << std::fixed << std::setprecision(2)
              << (total_ops / elapsed) << " ops/sec" << std::endl;
    std::cout << "Total time: " << std::fixed << std::setprecision(2) << elapsed << " seconds" << std::endl;

    db.Close();
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        PrintUsage(argv[0]);
        return 1;
    }

    std::string command = argv[1];
    std::string workload_file;
    std::string db_path = "/tmp/rocksdb-ycsb";

    // Parse arguments
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-P" && i + 1 < argc) {
            workload_file = argv[++i];
        } else if (arg == "-db" && i + 1 < argc) {
            db_path = argv[++i];
        }
    }

    if (workload_file.empty()) {
        std::cerr << "Error: Workload file not specified (-P option)" << std::endl;
        PrintUsage(argv[0]);
        return 1;
    }

    if (command == "load") {
        return DoLoad(workload_file, db_path);
    } else if (command == "run") {
        return DoRun(workload_file, db_path);
    } else {
        std::cerr << "Error: Unknown command '" << command << "'" << std::endl;
        PrintUsage(argv[0]);
        return 1;
    }

    return 0;
}

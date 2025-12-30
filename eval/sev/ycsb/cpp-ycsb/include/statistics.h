#pragma once

#include <string>
#include <chrono>
#include <vector>
#include <algorithm>

namespace ycsb {

class Statistics {
public:
    Statistics() : count_(0), total_latency_(0), min_latency_(UINT64_MAX), max_latency_(0) {}

    void Record(uint64_t latency_us) {
        count_++;
        total_latency_ += latency_us;
        min_latency_ = std::min(min_latency_, latency_us);
        max_latency_ = std::max(max_latency_, latency_us);
        latencies_.push_back(latency_us);
    }

    uint64_t GetCount() const { return count_; }
    double GetAvgLatency() const {
        return count_ > 0 ? static_cast<double>(total_latency_) / count_ : 0;
    }
    uint64_t GetMinLatency() const { return min_latency_; }
    uint64_t GetMaxLatency() const { return max_latency_; }

    double GetPercentileLatency(double percentile) const {
        if (latencies_.empty()) return 0;
        // Create a mutable copy for sorting
        std::vector<uint64_t> sorted_latencies = latencies_;
        std::sort(sorted_latencies.begin(), sorted_latencies.end());
        size_t index = static_cast<size_t>(sorted_latencies.size() * percentile);
        if (index >= sorted_latencies.size()) index = sorted_latencies.size() - 1;
        return sorted_latencies[index];
    }

    void Reset() {
        count_ = 0;
        total_latency_ = 0;
        min_latency_ = UINT64_MAX;
        max_latency_ = 0;
        latencies_.clear();
    }

private:
    uint64_t count_;
    uint64_t total_latency_;
    uint64_t min_latency_;
    uint64_t max_latency_;
    std::vector<uint64_t> latencies_;
};

class Timer {
public:
    Timer() : start_(std::chrono::high_resolution_clock::now()) {}

    uint64_t ElapsedMicros() {
        auto end = std::chrono::high_resolution_clock::now();
        return std::chrono::duration_cast<std::chrono::microseconds>(end - start_).count();
    }

    void Reset() {
        start_ = std::chrono::high_resolution_clock::now();
    }

private:
    std::chrono::high_resolution_clock::time_point start_;
};

} // namespace ycsb

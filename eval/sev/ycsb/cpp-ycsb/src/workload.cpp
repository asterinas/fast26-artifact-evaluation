#include "workload.h"
#include <fstream>
#include <sstream>
#include <iostream>
#include <ctime>

namespace ycsb {

Workload::Workload()
    : record_count_(1000),
      operation_count_(1000),
      field_count_(10),
      field_length_(100),
      read_proportion_(0.5),
      update_proportion_(0.5),
      insert_proportion_(0.0),
      scan_proportion_(0.0),
      read_modify_write_proportion_(0.0),
      scan_length_(100),
      insert_key_sequence_(0),
      rng_(std::random_device{}()),
      op_dist_(0.0, 1.0) {
}

bool Workload::LoadFromFile(const std::string& filename) {
    std::ifstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Failed to open workload file: " << filename << std::endl;
        return false;
    }

    std::string line;
    while (std::getline(file, line)) {
        // Skip comments and empty lines
        if (line.empty() || line[0] == '#') continue;

        // Parse key=value
        size_t pos = line.find('=');
        if (pos != std::string::npos) {
            std::string key = line.substr(0, pos);
            std::string value = line.substr(pos + 1);
            properties_[key] = value;
        }
    }

    // Load properties
    record_count_ = GetPropertyInt("recordcount", 1000);
    operation_count_ = GetPropertyInt("operationcount", 1000);
    field_count_ = GetPropertyInt("fieldcount", 10);
    field_length_ = GetPropertyInt("fieldlength", 100);

    read_proportion_ = GetPropertyDouble("readproportion", 0.5);
    update_proportion_ = GetPropertyDouble("updateproportion", 0.5);
    insert_proportion_ = GetPropertyDouble("insertproportion", 0.0);
    scan_proportion_ = GetPropertyDouble("scanproportion", 0.0);
    read_modify_write_proportion_ = GetPropertyDouble("readmodifywriteproportion", 0.0);

    scan_length_ = GetPropertyInt("maxscanlength", 100);

    // Initialize key distribution
    key_dist_ = std::uniform_int_distribution<int>(0, record_count_ - 1);

    insert_key_sequence_ = record_count_;

    std::cout << "Workload loaded: " << filename << std::endl;
    std::cout << "  Record count: " << record_count_ << std::endl;
    std::cout << "  Operation count: " << operation_count_ << std::endl;
    std::cout << "  Read: " << read_proportion_ << ", Update: " << update_proportion_
              << ", Insert: " << insert_proportion_ << ", Scan: " << scan_proportion_
              << ", RMW: " << read_modify_write_proportion_ << std::endl;

    return true;
}

std::string Workload::GetProperty(const std::string& key, const std::string& default_val) {
    auto it = properties_.find(key);
    return (it != properties_.end()) ? it->second : default_val;
}

int Workload::GetPropertyInt(const std::string& key, int default_val) {
    std::string val = GetProperty(key, "");
    return val.empty() ? default_val : std::stoi(val);
}

double Workload::GetPropertyDouble(const std::string& key, double default_val) {
    std::string val = GetProperty(key, "");
    return val.empty() ? default_val : std::stod(val);
}

Workload::Operation Workload::NextOperation() {
    double r = op_dist_(rng_);

    if (r < read_proportion_) {
        return Operation::READ;
    }
    r -= read_proportion_;

    if (r < update_proportion_) {
        return Operation::UPDATE;
    }
    r -= update_proportion_;

    if (r < insert_proportion_) {
        return Operation::INSERT;
    }
    r -= insert_proportion_;

    if (r < scan_proportion_) {
        return Operation::SCAN;
    }
    r -= scan_proportion_;

    if (r < read_modify_write_proportion_) {
        return Operation::READ_MODIFY_WRITE;
    }

    return Operation::READ; // Default
}

std::string Workload::NextKeyForRead() {
    return "user" + std::to_string(key_dist_(rng_));
}

std::string Workload::NextKeyForUpdate() {
    return "user" + std::to_string(key_dist_(rng_));
}

std::string Workload::NextKeyForInsert() {
    return "user" + std::to_string(insert_key_sequence_++);
}

std::string Workload::NextKeyForScan() {
    return "user" + std::to_string(key_dist_(rng_));
}

std::string Workload::NextKeyForReadModifyWrite() {
    return "user" + std::to_string(key_dist_(rng_));
}

std::string Workload::FieldName(int index) {
    return "field" + std::to_string(index);
}

std::string Workload::RandomValue() {
    static const char charset[] =
        "0123456789"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz";
    static const size_t charset_size = sizeof(charset) - 1;

    std::string result;
    result.reserve(field_length_);

    std::uniform_int_distribution<int> char_dist(0, charset_size - 1);
    for (int i = 0; i < field_length_; ++i) {
        result += charset[char_dist(rng_)];
    }

    return result;
}

} // namespace ycsb

#pragma once

#include <string>
#include <map>
#include <random>

namespace ycsb {

class Workload {
public:
    Workload();

    // Load workload configuration from file
    bool LoadFromFile(const std::string& filename);

    // Get properties
    int GetRecordCount() const { return record_count_; }
    int GetOperationCount() const { return operation_count_; }
    int GetFieldCount() const { return field_count_; }
    int GetFieldLength() const { return field_length_; }

    double GetReadProportion() const { return read_proportion_; }
    double GetUpdateProportion() const { return update_proportion_; }
    double GetInsertProportion() const { return insert_proportion_; }
    double GetScanProportion() const { return scan_proportion_; }
    double GetReadModifyWriteProportion() const { return read_modify_write_proportion_; }

    int GetScanLength() const { return scan_length_; }

    // Generate next operation type
    enum class Operation {
        READ,
        UPDATE,
        INSERT,
        SCAN,
        READ_MODIFY_WRITE
    };

    Operation NextOperation();

    // Generate key based on operation
    std::string NextKeyForRead();
    std::string NextKeyForUpdate();
    std::string NextKeyForInsert();
    std::string NextKeyForScan();
    std::string NextKeyForReadModifyWrite();

    // Generate field name
    std::string FieldName(int index);

    // Generate random value
    std::string RandomValue();

private:
    int record_count_;
    int operation_count_;
    int field_count_;
    int field_length_;

    double read_proportion_;
    double update_proportion_;
    double insert_proportion_;
    double scan_proportion_;
    double read_modify_write_proportion_;

    int scan_length_;

    int insert_key_sequence_;

    std::mt19937 rng_;
    std::uniform_real_distribution<double> op_dist_;
    std::uniform_int_distribution<int> key_dist_;

    // Parse property file
    std::map<std::string, std::string> properties_;
    std::string GetProperty(const std::string& key, const std::string& default_val);
    int GetPropertyInt(const std::string& key, int default_val);
    double GetPropertyDouble(const std::string& key, double default_val);
};

} // namespace ycsb

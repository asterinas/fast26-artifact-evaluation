#pragma once

#include "db.h"
#include <rocksdb/db.h>
#include <memory>

namespace ycsb {

class RocksDBDatabase : public DB {
public:
    RocksDBDatabase(const std::string& db_path);
    ~RocksDBDatabase() override;

    Status Init() override;
    void Close() override;
    Status Read(const std::string& key, Fields& result) override;
    Status Update(const std::string& key, const Fields& values) override;
    Status Insert(const std::string& key, const Fields& values) override;
    Status Delete(const std::string& key) override;
    Status Scan(const std::string& start_key, int count,
               std::vector<Fields>& result) override;
    Status ReadModifyWrite(const std::string& key, const Fields& values) override;

private:
    std::string db_path_;
    rocksdb::DB* db_;
    rocksdb::Options options_;

    // Serialize fields to string
    std::string SerializeFields(const Fields& fields);

    // Deserialize string to fields
    Fields DeserializeFields(const std::string& data);
};

} // namespace ycsb

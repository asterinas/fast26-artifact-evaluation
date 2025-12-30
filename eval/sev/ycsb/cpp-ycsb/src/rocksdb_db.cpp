#include "rocksdb_db.h"
#include <rocksdb/options.h>
#include <iostream>
#include <sstream>

namespace ycsb {

RocksDBDatabase::RocksDBDatabase(const std::string& db_path)
    : db_path_(db_path), db_(nullptr) {
}

RocksDBDatabase::~RocksDBDatabase() {
    Close();
}

Status RocksDBDatabase::Init() {
    options_.create_if_missing = true;
    options_.write_buffer_size = 64 * 1024 * 1024; // 64MB
    options_.max_write_buffer_number = 3;
    options_.target_file_size_base = 64 * 1024 * 1024;
    options_.max_bytes_for_level_base = 256 * 1024 * 1024;

    rocksdb::Status s = rocksdb::DB::Open(options_, db_path_, &db_);
    if (!s.ok()) {
        std::cerr << "Failed to open RocksDB: " << s.ToString() << std::endl;
        return Status::ERROR;
    }

    std::cout << "RocksDB opened at: " << db_path_ << std::endl;
    return Status::OK;
}

void RocksDBDatabase::Close() {
    if (db_) {
        delete db_;
        db_ = nullptr;
    }
}

Status RocksDBDatabase::Read(const std::string& key, Fields& result) {
    std::string value;
    rocksdb::Status s = db_->Get(rocksdb::ReadOptions(), key, &value);

    if (s.IsNotFound()) {
        return Status::NOT_FOUND;
    }
    if (!s.ok()) {
        return Status::ERROR;
    }

    result = DeserializeFields(value);
    return Status::OK;
}

Status RocksDBDatabase::Update(const std::string& key, const Fields& values) {
    // For simplicity, we just overwrite the entire record
    std::string value = SerializeFields(values);
    rocksdb::Status s = db_->Put(rocksdb::WriteOptions(), key, value);

    return s.ok() ? Status::OK : Status::ERROR;
}

Status RocksDBDatabase::Insert(const std::string& key, const Fields& values) {
    std::string value = SerializeFields(values);
    rocksdb::Status s = db_->Put(rocksdb::WriteOptions(), key, value);

    return s.ok() ? Status::OK : Status::ERROR;
}

Status RocksDBDatabase::Delete(const std::string& key) {
    rocksdb::Status s = db_->Delete(rocksdb::WriteOptions(), key);
    return s.ok() ? Status::OK : Status::ERROR;
}

Status RocksDBDatabase::Scan(const std::string& start_key, int count,
                             std::vector<Fields>& result) {
    rocksdb::Iterator* it = db_->NewIterator(rocksdb::ReadOptions());

    int scanned = 0;
    for (it->Seek(start_key); it->Valid() && scanned < count; it->Next()) {
        Fields fields = DeserializeFields(it->value().ToString());
        result.push_back(fields);
        scanned++;
    }

    bool success = it->status().ok();
    delete it;

    return success ? Status::OK : Status::ERROR;
}

Status RocksDBDatabase::ReadModifyWrite(const std::string& key, const Fields& values) {
    // Read the existing record
    std::string existing_value;
    rocksdb::Status s = db_->Get(rocksdb::ReadOptions(), key, &existing_value);

    Fields fields;
    if (s.ok()) {
        // Deserialize existing fields
        fields = DeserializeFields(existing_value);
    }
    // If not found, start with empty fields

    // Modify with new values
    for (const auto& pair : values) {
        fields[pair.first] = pair.second;
    }

    // Write back
    std::string new_value = SerializeFields(fields);
    s = db_->Put(rocksdb::WriteOptions(), key, new_value);

    return s.ok() ? Status::OK : Status::ERROR;
}

std::string RocksDBDatabase::SerializeFields(const Fields& fields) {
    std::ostringstream oss;
    for (const auto& pair : fields) {
        oss << pair.first << "=" << pair.second << ";";
    }
    return oss.str();
}

Fields RocksDBDatabase::DeserializeFields(const std::string& data) {
    Fields fields;
    std::istringstream iss(data);
    std::string field;

    while (std::getline(iss, field, ';')) {
        if (field.empty()) continue;

        size_t pos = field.find('=');
        if (pos != std::string::npos) {
            std::string key = field.substr(0, pos);
            std::string value = field.substr(pos + 1);
            fields[key] = value;
        }
    }

    return fields;
}

} // namespace ycsb

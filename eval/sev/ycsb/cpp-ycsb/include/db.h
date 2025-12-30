#pragma once

#include <string>
#include <vector>
#include <map>

namespace ycsb {

// Status code for DB operations
enum class Status {
    OK = 0,
    NOT_FOUND,
    ERROR
};

// Field-value pair
using Fields = std::map<std::string, std::string>;

// Abstract database interface
class DB {
public:
    virtual ~DB() = default;

    // Initialize database
    virtual Status Init() = 0;

    // Close database
    virtual void Close() = 0;

    // Read a record
    virtual Status Read(const std::string& key, Fields& result) = 0;

    // Update a record
    virtual Status Update(const std::string& key, const Fields& values) = 0;

    // Insert a record
    virtual Status Insert(const std::string& key, const Fields& values) = 0;

    // Delete a record
    virtual Status Delete(const std::string& key) = 0;

    // Scan records starting from key
    virtual Status Scan(const std::string& start_key, int count,
                       std::vector<Fields>& result) = 0;

    // Read-modify-write: atomically read, modify, and write back
    virtual Status ReadModifyWrite(const std::string& key, const Fields& values) = 0;
};

} // namespace ycsb

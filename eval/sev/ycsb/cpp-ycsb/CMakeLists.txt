cmake_minimum_required(VERSION 3.10)
project(cpp-ycsb)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Include directories
include_directories(${PROJECT_SOURCE_DIR}/include)

# Try to find RocksDB using pkg-config first
find_package(PkgConfig)
if(PkgConfig_FOUND)
    pkg_check_modules(ROCKSDB rocksdb)
endif()

# If pkg-config didn't find it, search manually
if(NOT ROCKSDB_FOUND)
    # Search for header
    find_path(ROCKSDB_INCLUDE_DIR
        NAMES rocksdb/db.h
        PATHS /usr/include /usr/local/include
    )

    # Search for library
    find_library(ROCKSDB_LIBRARY
        NAMES rocksdb
        PATHS /usr/lib /usr/local/lib /usr/lib/x86_64-linux-gnu
    )

    if(ROCKSDB_INCLUDE_DIR AND ROCKSDB_LIBRARY)
        set(ROCKSDB_FOUND TRUE)
        set(ROCKSDB_INCLUDE_DIRS ${ROCKSDB_INCLUDE_DIR})
        set(ROCKSDB_LIBRARIES ${ROCKSDB_LIBRARY})
        message(STATUS "Found RocksDB: ${ROCKSDB_LIBRARY}")
    else()
        message(FATAL_ERROR "RocksDB not found! Please install librocksdb-dev or build from source.")
    endif()
endif()

# Include RocksDB headers
include_directories(${ROCKSDB_INCLUDE_DIRS})

# Source files
set(SOURCES
    src/main.cpp
    src/rocksdb_db.cpp
    src/workload.cpp
)

# Executable
add_executable(ycsb ${SOURCES})

# Find optional compression libraries
find_library(LZ4_LIBRARY lz4)
find_library(ZSTD_LIBRARY zstd)
find_library(SNAPPY_LIBRARY snappy)
find_library(BZ2_LIBRARY bz2)
find_library(Z_LIBRARY z)

# Build list of libraries to link
set(LINK_LIBRARIES
    ${ROCKSDB_LIBRARIES}
    pthread
    dl
)

# Add compression libraries if found
if(Z_LIBRARY)
    list(APPEND LINK_LIBRARIES ${Z_LIBRARY})
endif()
if(BZ2_LIBRARY)
    list(APPEND LINK_LIBRARIES ${BZ2_LIBRARY})
endif()
if(LZ4_LIBRARY)
    list(APPEND LINK_LIBRARIES ${LZ4_LIBRARY})
endif()
if(ZSTD_LIBRARY)
    list(APPEND LINK_LIBRARIES ${ZSTD_LIBRARY})
endif()
if(SNAPPY_LIBRARY)
    list(APPEND LINK_LIBRARIES ${SNAPPY_LIBRARY})
endif()

# Link libraries
target_link_libraries(ycsb ${LINK_LIBRARIES})

# Set output directory
set_target_properties(ycsb PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${PROJECT_SOURCE_DIR}/bin
)

# Install target
install(TARGETS ycsb DESTINATION bin)

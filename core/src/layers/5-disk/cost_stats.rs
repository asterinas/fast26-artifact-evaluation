//! Cost statistics for read/write operations.

use core::sync::atomic::{AtomicU64, AtomicBool, Ordering};
use lazy_static::lazy_static;

/// Cost statistics collector
pub struct CostStats {
    read_count: AtomicU64,
    read_bytes: AtomicU64,
    write_count: AtomicU64,
    write_bytes: AtomicU64,
}

impl CostStats {
    /// Create a new CostStats instance
    pub const fn new() -> Self {
        Self {
            read_count: AtomicU64::new(0),
            read_bytes: AtomicU64::new(0),
            write_count: AtomicU64::new(0),
            write_bytes: AtomicU64::new(0),
        }
    }

    /// Add a read operation
    pub fn add_read(&self, bytes: u64) {
        self.read_count.fetch_add(1, Ordering::Relaxed);
        self.read_bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    /// Add a write operation
    pub fn add_write(&self, bytes: u64) {
        self.write_count.fetch_add(1, Ordering::Relaxed);
        self.write_bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    /// Get total read operations count
    pub fn get_read_count(&self) -> u64 {
        self.read_count.load(Ordering::Relaxed)
    }

    /// Get total read bytes
    pub fn get_read_bytes(&self) -> u64 {
        self.read_bytes.load(Ordering::Relaxed)
    }

    /// Get total write operations count
    pub fn get_write_count(&self) -> u64 {
        self.write_count.load(Ordering::Relaxed)
    }

    /// Get total write bytes
    pub fn get_write_bytes(&self) -> u64 {
        self.write_bytes.load(Ordering::Relaxed)
    }

    /// Reset all statistics
    pub fn reset(&self) {
        self.read_count.store(0, Ordering::Relaxed);
        self.read_bytes.store(0, Ordering::Relaxed);
        self.write_count.store(0, Ordering::Relaxed);
        self.write_bytes.store(0, Ordering::Relaxed);
    }

    /// Print statistics
    pub fn print(&self) {
        let read_count = self.get_read_count();
        let read_bytes = self.get_read_bytes();
        let write_count = self.get_write_count();
        let write_bytes = self.get_write_bytes();

        println!("==================== Cost Statistics ====================");
        println!("  Read operations:  {} times", read_count);
        println!("  Read bytes:       {} bytes ({:.2} MB)", read_bytes, read_bytes as f64 / 1024.0 / 1024.0);
        println!("  Write operations: {} times", write_count);
        println!("  Write bytes:      {} bytes ({:.2} MB)", write_bytes, write_bytes as f64 / 1024.0 / 1024.0);
        println!("  Total operations: {} times", read_count + write_count);
        println!("  Total bytes:      {} bytes ({:.2} MB)",
                read_bytes + write_bytes,
                (read_bytes + write_bytes) as f64 / 1024.0 / 1024.0);
        println!("=========================================================");
    }
}

// Global Cost statistics
lazy_static! {
    pub static ref COST_STATS: CostStats = CostStats::new();
}

// ============================================================================
// Cost Timing Statistics (L3: Disk Layer, L2: LSM Tree Layer)
// Uses RDTSC for low-overhead timing (no OCall needed in SGX)
// ============================================================================

#[derive(Debug, Clone, Copy)]
pub enum CostL3Type {
    LogicalBlockTable,
    BlockIO,
    Encryption,
    Allocation,
}

#[derive(Debug, Clone, Copy)]
pub enum CostL2Type {
    WAL,
    MemTable,
    Compaction,
    SSTableLookup,
}

/// L3 Layer (Disk Layer) cost statistics
pub struct CostL3 {
    logical_block_table: AtomicU64,
    block_io: AtomicU64,
    encryption: AtomicU64,
    allocation: AtomicU64,
}

impl CostL3 {
    pub const fn new() -> Self {
        Self {
            logical_block_table: AtomicU64::new(0),
            block_io: AtomicU64::new(0),
            encryption: AtomicU64::new(0),
            allocation: AtomicU64::new(0),
        }
    }

    pub fn time(&self, op_type: CostL3Type) -> CostTimer {
        let target = match op_type {
            CostL3Type::LogicalBlockTable => &self.logical_block_table,
            CostL3Type::BlockIO => &self.block_io,
            CostL3Type::Encryption => &self.encryption,
            CostL3Type::Allocation => &self.allocation,
        };
        CostTimer::new(target)
    }

    pub fn get_stats(&self) -> CostL3Stats {
        let logical_block_table = self.logical_block_table.load(Ordering::Relaxed);
        let block_io = self.block_io.load(Ordering::Relaxed);
        let encryption = self.encryption.load(Ordering::Relaxed);
        let allocation = self.allocation.load(Ordering::Relaxed);
        let total = logical_block_table + block_io + encryption + allocation;

        CostL3Stats {
            logical_block_table,
            block_io,
            encryption,
            allocation,
            total,
        }
    }

    pub fn reset(&self) {
        self.logical_block_table.store(0, Ordering::Relaxed);
        self.block_io.store(0, Ordering::Relaxed);
        self.encryption.store(0, Ordering::Relaxed);
        self.allocation.store(0, Ordering::Relaxed);
    }

    pub fn print(&self) {
        let stats = self.get_stats();
        stats.print();
    }
}


/// L2 Layer (LSM Tree Layer) cost statistics
pub struct CostL2 {
    wal: AtomicU64,
    memtable: AtomicU64,
    compaction: AtomicU64,
    sstable_lookup: AtomicU64,
}

impl CostL2 {
    pub const fn new() -> Self {
        Self {
            wal: AtomicU64::new(0),
            memtable: AtomicU64::new(0),
            compaction: AtomicU64::new(0),
            sstable_lookup: AtomicU64::new(0),
        }
    }

    pub fn time(&self, op_type: CostL2Type) -> CostTimer {
        let target = match op_type {
            CostL2Type::WAL => &self.wal,
            CostL2Type::MemTable => &self.memtable,
            CostL2Type::Compaction => &self.compaction,
            CostL2Type::SSTableLookup => &self.sstable_lookup,
        };
        CostTimer::new(target)
    }

    pub fn get_stats(&self) -> CostL2Stats {
        let wal = self.wal.load(Ordering::Relaxed);
        let memtable = self.memtable.load(Ordering::Relaxed);
        let compaction = self.compaction.load(Ordering::Relaxed);
        let sstable_lookup = self.sstable_lookup.load(Ordering::Relaxed);
        let total = wal + memtable + compaction + sstable_lookup;

        CostL2Stats {
            wal,
            memtable,
            compaction,
            sstable_lookup,
            total,
        }
    }

    pub fn reset(&self) {
        self.wal.store(0, Ordering::Relaxed);
        self.memtable.store(0, Ordering::Relaxed);
        self.compaction.store(0, Ordering::Relaxed);
        self.sstable_lookup.store(0, Ordering::Relaxed);
    }

    pub fn print(&self) {
        let stats = self.get_stats();
        stats.print();
    }
}

/// Read CPU timestamp counter (RDTSC) - no OCall needed, very fast
#[inline]
fn rdtsc() -> u64 {
    #[cfg(target_arch = "x86_64")]
    unsafe {
        core::arch::x86_64::_rdtsc()
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        0
    }
}

pub struct CostTimer<'a> {
    start: u64,
    target: &'a AtomicU64,
}

impl<'a> CostTimer<'a> {
    pub fn new(target: &'a AtomicU64) -> Self {
        Self {
            start: rdtsc(),
            target,
        }
    }
}

impl<'a> Drop for CostTimer<'a> {
    fn drop(&mut self) {
        let elapsed_cycles = rdtsc().saturating_sub(self.start);
        self.target.fetch_add(elapsed_cycles, Ordering::Relaxed);
    }
}

/// CPU cycles statistics (using RDTSC)
#[derive(Debug, Clone)]
pub struct CostL3Stats {
    pub logical_block_table: u64,
    pub block_io: u64,
    pub encryption: u64,
    pub allocation: u64,
    pub total: u64,
}

impl CostL3Stats {
    pub fn get_percentage(&self) -> CostL3Percentage {
        if self.total == 0 {
            return CostL3Percentage::default();
        }

        let total = self.total as f64;
        CostL3Percentage {
            logical_block_table: (self.logical_block_table as f64 / total) * 100.0,
            block_io: (self.block_io as f64 / total) * 100.0,
            encryption: (self.encryption as f64 / total) * 100.0,
            allocation: (self.allocation as f64 / total) * 100.0,
        }
    }

    pub fn print(&self) {
        let pct = self.get_percentage();

        println!("=============== L3 (Disk Layer) Cost Statistics ===============");
        println!("  (Unit: CPU cycles, measured via RDTSC)");
        println!("  Logical Block Table: {:>15} cycles ({:>5.2}%)",
                 self.logical_block_table,
                 pct.logical_block_table);
        println!("  Block I/O:           {:>15} cycles ({:>5.2}%)",
                 self.block_io,
                 pct.block_io);
        println!("  Encryption:          {:>15} cycles ({:>5.2}%)",
                 self.encryption,
                 pct.encryption);
        println!("  Allocation:          {:>15} cycles ({:>5.2}%)",
                 self.allocation,
                 pct.allocation);
        println!("  {}", "-".repeat(63));
        println!("  Total:               {:>15} cycles",
                 self.total);
        println!("================================================================");
    }
}

/// CPU cycles statistics (using RDTSC)
#[derive(Debug, Clone)]
pub struct CostL2Stats {
    pub wal: u64,
    pub memtable: u64,
    pub compaction: u64,
    pub sstable_lookup: u64,
    pub total: u64,
}

impl CostL2Stats {
    pub fn get_percentage(&self) -> CostL2Percentage {
        if self.total == 0 {
            return CostL2Percentage::default();
        }

        let total = self.total as f64;
        CostL2Percentage {
            wal: (self.wal as f64 / total) * 100.0,
            memtable: (self.memtable as f64 / total) * 100.0,
            compaction: (self.compaction as f64 / total) * 100.0,
            sstable_lookup: (self.sstable_lookup as f64 / total) * 100.0,
        }
    }

    pub fn print(&self) {
        let pct = self.get_percentage();

        println!("============= L2 (LSM Tree Layer) Cost Statistics =============");
        println!("  (Unit: CPU cycles, measured via RDTSC)");
        println!("  WAL:                 {:>15} cycles ({:>5.2}%)",
                 self.wal,
                 pct.wal);
        println!("  MemTable:            {:>15} cycles ({:>5.2}%)",
                 self.memtable,
                 pct.memtable);
        println!("  Compaction:          {:>15} cycles ({:>5.2}%)",
                 self.compaction,
                 pct.compaction);
        println!("  SSTable Lookup:      {:>15} cycles ({:>5.2}%)",
                 self.sstable_lookup,
                 pct.sstable_lookup);
        println!("  {}", "-".repeat(63));
        println!("  Total:               {:>15} cycles",
                 self.total);
        println!("================================================================");
    }
}

#[derive(Debug, Default, Clone)]
pub struct CostL3Percentage {
    pub logical_block_table: f64,
    pub block_io: f64,
    pub encryption: f64,
    pub allocation: f64,
}

#[derive(Debug, Default, Clone)]
pub struct CostL2Percentage {
    pub wal: f64,
    pub memtable: f64,
    pub compaction: f64,
    pub sstable_lookup: f64,
}

lazy_static! {
    pub static ref COST_L3: CostL3 = CostL3::new();
    pub static ref COST_L2: CostL2 = CostL2::new();
}

pub fn print_all_cost_stats() {
    COST_L3.print();
    println!();
    COST_L2.print();
}

// ============================================================================
// Reset After Warmup Reads
// ============================================================================

/// Counter to track read requests
static READ_COUNT: AtomicU64 = AtomicU64::new(0);

/// Flag to ensure we only reset once
static COST_RESET_DONE: AtomicBool = AtomicBool::new(false);

/// Reset threshold: FIO sends ~770 warmup reads, so reset at 800th read
const RESET_AFTER_READS: u64 = 800;

/// Count read operations and reset cost statistics after warmup phase.
/// This is called at the start of read operations to exclude FIO layout/warmup overhead.
/// Resets once at the 800th read, subsequent calls do nothing (idempotent).
pub fn reset_cost_on_first_read() {
    let count = READ_COUNT.fetch_add(1, Ordering::Relaxed) + 1;

    // Reset at exactly the 800th read
    if count == RESET_AFTER_READS {
        // Use compare_exchange to ensure only one thread resets
        if COST_RESET_DONE.compare_exchange(
            false,
            true,
            Ordering::SeqCst,
            Ordering::SeqCst
        ).is_ok() {
            println!("========================================");
            println!("Cost stats reset at read #{}", count);
            println!("Excluding warmup phase from statistics");
            println!("========================================");

            // Reset all cost statistics
            COST_L3.reset();
            COST_L2.reset();
            COST_STATS.reset();
        }
    }
}



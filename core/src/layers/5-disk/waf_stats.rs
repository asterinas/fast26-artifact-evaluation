//! Write Amplification Factor (WAF) statistics.

use core::sync::atomic::{AtomicU64, Ordering};
use lazy_static::lazy_static;

/// WAF statistics collector
pub struct WafStats {
    logical_bytes: AtomicU64,
    physical_bytes: AtomicU64,
}

impl WafStats {
    /// Create a new WafStats instance
    pub const fn new() -> Self {
        Self {
            logical_bytes: AtomicU64::new(0),
            physical_bytes: AtomicU64::new(0),
        }
    }

    /// Add logical write bytes (writes to user_data_disk)
    pub fn add_logical(&self, bytes: u64) {
        self.logical_bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    /// Add physical write bytes (writes to underlying block_set)
    pub fn add_physical(&self, bytes: u64) {
        self.physical_bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    /// Get total logical write bytes
    pub fn get_logical(&self) -> u64 {
        self.logical_bytes.load(Ordering::Relaxed)
    }

    /// Get total physical write bytes
    pub fn get_physical(&self) -> u64 {
        self.physical_bytes.load(Ordering::Relaxed)
    }

    /// Calculate Write Amplification Factor
    pub fn waf(&self) -> f64 {
        let logical = self.get_logical() as f64;
        let physical = self.get_physical() as f64;
        if logical > 0.0 {
            physical / logical
        } else {
            0.0
        }
    }

    /// Reset all statistics
    pub fn reset(&self) {
        self.logical_bytes.store(0, Ordering::Relaxed);
        self.physical_bytes.store(0, Ordering::Relaxed);
    }

    /// Print statistics
    pub fn print(&self) {
        let logical = self.get_logical();
        let physical = self.get_physical();
        let waf = self.waf();

        println!("==================== WAF Statistics ====================");
        println!("  Logical writes:  {} bytes ({:.2} MB)", logical, logical as f64 / 1024.0 / 1024.0);
        println!("  Physical writes: {} bytes ({:.2} MB)", physical, physical as f64 / 1024.0 / 1024.0);
        println!("  WAF:             {:.3}", waf);
        println!("========================================================");
    }
}

// Global WAF statistics
lazy_static! {
    pub static ref WAF_STATS: WafStats = WafStats::new();
}

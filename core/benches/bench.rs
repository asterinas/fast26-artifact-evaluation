//! Benchmarks of the system.
//!
//! Supports sequential/random write/read workloads.
//! Write/read amount, concurrency and I/O buffer size are configurable.
//! Provides a baseline named `EncDisk`, which simply protects data using authenticated encryption.
//! Results are displayed as throughput in MiB/sec.
use sworndisk_v2::*;

use self::benches::{Bench, BenchBuilder, IoPattern, IoType};
use self::consts::*;
use self::disks::{DiskType, FileAsDisk};
use self::util::{DisplayData, DisplayThroughput};

use libc::{fdatasync, ftruncate, open, pread, pwrite, unlink, O_CREAT, O_DIRECT, O_RDWR, O_TRUNC};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Instant, Duration};
use std::thread;

fn main() {
    let total_bytes = 50 * GiB;
    // Specify all benchmarks
    let benches = vec![
        // BenchBuilder::new("SwornDisk::write_seq")
        //     .disk_type(DiskType::SwornDisk)
        //     .io_type(IoType::Write)
        //     .io_pattern(IoPattern::Seq)
        //     .total_bytes(total_bytes)
        //     .buf_size(512 * KiB)
        //     .concurrency(1)
        //     .build()
        //     .unwrap(),
        // BenchBuilder::new("SwornDisk::write_rnd")
        //     .disk_type(DiskType::SwornDisk)
        //     .io_type(IoType::Write)
        //     .io_pattern(IoPattern::Rnd)
        //     .total_bytes(total_bytes)
        //     .buf_size(4 * KiB)
        //     .concurrency(1)
        //     .build()
        //     .unwrap(),
        // BenchBuilder::new("SwornDisk::read_seq")
        //     .disk_type(DiskType::SwornDisk)
        //     .io_type(IoType::Read)
        //     .io_pattern(IoPattern::Seq)
        //     .total_bytes(total_bytes)
        //     .buf_size(1 * MiB)
        //     .concurrency(1)
        //     .build()
        //     .unwrap(),
        BenchBuilder::new("SwornDisk::read_rnd")
            .disk_type(DiskType::SwornDisk)
            .io_type(IoType::Read)
            .io_pattern(IoPattern::Rnd)
            .total_bytes(total_bytes)
            .buf_size(4 * KiB)
            .concurrency(1)
            .build()
            .unwrap(),
        // Benchmark on `EncDisk` not enabled by default
        // BenchBuilder::new("EncDisk::write_seq")
        //     .disk_type(DiskType::EncDisk)
        //     .io_type(IoType::Write)
        //     .io_pattern(IoPattern::Seq)
        //     .total_bytes(total_bytes)
        //     .buf_size(256 * KiB)
        //     .concurrency(1)
        //     .build()
        //     .unwrap(),
    ];

    // Run all benchmarks and output the results
    run_benches(benches);
}

/// Throughput monitor that periodically outputs throughput statistics
struct ThroughputMonitor {
    completed_bytes: Arc<AtomicU64>,
    stop_flag: Arc<AtomicBool>,
    interval: Duration,
}

impl ThroughputMonitor {
    fn new(interval_secs: u64) -> Self {
        Self {
            completed_bytes: Arc::new(AtomicU64::new(0)),
            stop_flag: Arc::new(AtomicBool::new(false)),
            interval: Duration::from_secs(interval_secs),
        }
    }

    /// Start monitoring thread that outputs throughput periodically
    fn start(&self) -> thread::JoinHandle<()> {
        let completed_bytes = self.completed_bytes.clone();
        let stop_flag = self.stop_flag.clone();
        let interval = self.interval;

        thread::spawn(move || {
            let start_time = Instant::now();
            let mut last_bytes = 0u64;
            let mut last_time = start_time;

            while !stop_flag.load(Ordering::Relaxed) {
                thread::sleep(interval);

                let current_bytes = completed_bytes.load(Ordering::Relaxed);
                let current_time = Instant::now();

                // Calculate instantaneous throughput
                let bytes_delta = current_bytes - last_bytes;
                let time_delta = current_time.duration_since(last_time);
                let instant_throughput = DisplayThroughput::new(bytes_delta as usize, time_delta);

                // Calculate average throughput
                let total_elapsed = current_time.duration_since(start_time);
                let avg_throughput = DisplayThroughput::new(current_bytes as usize, total_elapsed);

                println!(
                    "[{:>6.1}s] Instant: {} | Average: {} | Completed: {}",
                    total_elapsed.as_secs_f64(),
                    instant_throughput,
                    avg_throughput,
                    DisplayData::new(current_bytes as usize)
                );

                last_bytes = current_bytes;
                last_time = current_time;
            }
        })
    }

    /// Stop the monitoring thread
    fn stop(&self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }

    /// Get a handle to update completed bytes
    fn get_counter(&self) -> Arc<AtomicU64> {
        self.completed_bytes.clone()
    }
}

fn run_benches(benches: Vec<Box<dyn Bench>>) {
    println!("");

    let mut benched_count = 0;
    let mut failed_count = 0;
    for b in benches {
        print!("bench {} ... ", &b);
        b.prepare();

        // Create throughput monitor
        let monitor = ThroughputMonitor::new(1); // Output every 1 second
        let counter = monitor.get_counter();
        let monitor_handle = monitor.start();

        let start = Instant::now();
        let res = b.run_with_progress(counter);
        let elapsed = start.elapsed();

        // Stop monitoring
        monitor.stop();
        let _ = monitor_handle.join();

        if let Err(e) = res {
            failed_count += 1;
            println!("failed due to error {:?}", e);
            continue;
        }

        let throughput = DisplayThroughput::new(b.total_bytes(), elapsed);
        println!("Final: {}", throughput);

        b.display_ext();
        benched_count += 1;
    }

    let bench_res = if failed_count == 0 { "ok" } else { "failed" };
    println!(
        "\nbench result: {}. {} benched; {} failed.",
        bench_res, benched_count, failed_count
    );
}

type Result<T> = core::result::Result<T, Error>;

mod benches {
    use super::disks::{BenchDisk, EncDisk};
    use super::*;

    use std::fmt::{self};
    use std::thread::{self, JoinHandle};

    pub trait Bench: fmt::Display {
        /// Returns the name of the benchmark.
        fn name(&self) -> &str;

        /// Returns the total number of bytes read or written.
        fn total_bytes(&self) -> usize;

        /// Do some preparatory work before running.
        fn prepare(&self) -> Result<()> {
            Ok(())
        }

        /// Run the benchmark.
        fn run(&self) -> Result<()>;

        /// Run the benchmark with progress tracking.
        fn run_with_progress(&self, progress_counter: Arc<AtomicU64>) -> Result<()>;

        /// Display extra information.
        fn display_ext(&self) {}
    }

    pub struct BenchBuilder {
        name: String,
        disk_type: Option<DiskType>,
        io_type: Option<IoType>,
        io_pattern: Option<IoPattern>,
        buf_size: usize,
        total_bytes: usize,
        concurrency: u32,
    }

    impl BenchBuilder {
        pub fn new(name: &str) -> Self {
            Self {
                name: name.to_string(),
                disk_type: None,
                io_type: None,
                io_pattern: None,
                buf_size: 4 * KiB,
                total_bytes: 1 * MiB,
                concurrency: 1,
            }
        }

        pub fn disk_type(mut self, disk_type: DiskType) -> Self {
            self.disk_type = Some(disk_type);
            self
        }

        pub fn io_type(mut self, io_type: IoType) -> Self {
            self.io_type = Some(io_type);
            self
        }

        pub fn io_pattern(mut self, io_pattern: IoPattern) -> Self {
            self.io_pattern = Some(io_pattern);
            self
        }

        pub fn buf_size(mut self, buf_size: usize) -> Self {
            self.buf_size = buf_size;
            self
        }

        pub fn total_bytes(mut self, total_bytes: usize) -> Self {
            self.total_bytes = total_bytes;
            self
        }

        pub fn concurrency(mut self, concurrency: u32) -> Self {
            self.concurrency = concurrency;
            self
        }

        pub fn build(self) -> Result<Box<dyn Bench>> {
            let Self {
                name,
                disk_type,
                io_type,
                io_pattern,
                buf_size,
                total_bytes,
                concurrency,
            } = self;

            let disk_type = match disk_type {
                Some(disk_type) => disk_type,
                None => return_errno_with_msg!(Errno::InvalidArgs, "disk_type is not given"),
            };
            let io_type = match io_type {
                Some(io_type) => io_type,
                None => return_errno_with_msg!(Errno::InvalidArgs, "io_type is not given"),
            };
            let io_pattern = match io_pattern {
                Some(io_pattern) => io_pattern,
                None => return_errno_with_msg!(Errno::InvalidArgs, "io_pattern is not given"),
            };
            if total_bytes == 0 || total_bytes % BLOCK_SIZE != 0 {
                return_errno_with_msg!(
                    Errno::InvalidArgs,
                    "total_bytes must be greater than 0 and a multiple of block size"
                );
            }
            if buf_size == 0 || buf_size % BLOCK_SIZE != 0 {
                return_errno_with_msg!(
                    Errno::InvalidArgs,
                    "buf_size must be greater than 0 and a multiple of block size"
                );
            }
            if concurrency == 0 {
                return_errno_with_msg!(Errno::InvalidArgs, "concurrency must be greater than 0");
            }

            let disk = Self::create_disk(total_bytes / BLOCK_SIZE, disk_type)?;
            Ok(Box::new(SimpleDiskBench {
                name,
                disk,
                io_type,
                io_pattern,
                buf_size,
                total_bytes,
                concurrency,
            }))
        }

        fn create_disk(total_nblocks: usize, disk_type: DiskType) -> Result<Arc<dyn BenchDisk>> {
            static DISK_ID: AtomicU32 = AtomicU32::new(0);

            let config = Config {
                cache_size: 600 * MiB,
                two_level_caching: false,
                delayed_reclamation: false,
            };
            
            let disk: Arc<dyn BenchDisk> = match disk_type {
                DiskType::SwornDisk => Arc::new(SwornDisk::create(
                    FileAsDisk::create(
                        total_nblocks * 5 / 4, // TBD
                        &format!(
                            "sworndisk-{}.image",
                            DISK_ID.fetch_add(1, Ordering::Release)
                        ),
                    ),
                    AeadKey::default(),
                    None,
                    Some(config),
                )?),

                DiskType::EncDisk => Arc::new(EncDisk::create(
                    total_nblocks,
                    &format!("encdisk-{}.image", DISK_ID.fetch_add(1, Ordering::Release)),
                )),
            };
            Ok(disk)
        }
    }

    pub struct SimpleDiskBench {
        name: String,
        disk: Arc<dyn BenchDisk>,
        io_type: IoType,
        io_pattern: IoPattern,
        buf_size: usize,
        total_bytes: usize,
        concurrency: u32,
    }

    impl Bench for SimpleDiskBench {
        fn name(&self) -> &str {
            &self.name
        }

        fn total_bytes(&self) -> usize {
            self.total_bytes
        }

        fn run(&self) -> Result<()> {
            self.run_with_progress(Arc::new(AtomicU64::new(0)))
        }

        fn run_with_progress(&self, progress_counter: Arc<AtomicU64>) -> Result<()> {
            let io_type = self.io_type;
            let io_pattern = self.io_pattern;
            let buf_nblocks = self.buf_size / BLOCK_SIZE;
            let total_nblocks = self.total_bytes / BLOCK_SIZE;
            let concurrency = self.concurrency;

            let local_nblocks = total_nblocks / (concurrency as usize);
            let join_handles: Vec<JoinHandle<Result<()>>> = (0..concurrency)
                .map(|i| {
                    let disk = self.disk.clone();
                    let local_pos = (i as BlockId) * local_nblocks;
                    let counter = progress_counter.clone();
                    let buf_size = self.buf_size;

                    thread::spawn(move || {
                        let result = match (io_type, io_pattern) {
                            (IoType::Read, IoPattern::Seq) => {
                                disk.read_seq_with_progress(local_pos, local_nblocks, buf_nblocks, counter)
                            }
                            (IoType::Write, IoPattern::Seq) => {
                                disk.write_seq_with_progress(local_pos, local_nblocks, buf_nblocks, counter)
                            }
                            (IoType::Read, IoPattern::Rnd) => {
                                disk.read_rnd_with_progress(local_pos, local_nblocks, buf_nblocks, counter)
                            }
                            (IoType::Write, IoPattern::Rnd) => {
                                disk.write_rnd_with_progress(local_pos, local_nblocks, buf_nblocks, counter)
                            }
                        };
                        result
                    })
                })
                .collect();

            let mut any_error = None;
            for join_handle in join_handles {
                let res = join_handle
                    .join()
                    .expect("couldn't join on the associated thread");
                if let Err(e) = res {
                    println!("benchmark task error: {:?}", &e);
                    any_error = Some(e);
                }
            }
            match any_error {
                None => Ok(()),
                Some(e) => Err(e),
            }
        }

        fn prepare(&self) -> Result<()> {
            if self.io_type == IoType::Write {
                return Ok(());
            }
            // Fill the disk before a read bench
            let disk = self.disk.clone();
            let total_nblocks = self.total_bytes / BLOCK_SIZE;
            thread::spawn(move || disk.write_seq(0 as BlockId, total_nblocks, 1024))
                .join()
                .unwrap()
        }

        fn display_ext(&self) {}
    }

    impl fmt::Display for SimpleDiskBench {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(
                f,
                "{} (total = {}, buf = {}, tasks = {})",
                self.name(),
                DisplayData::new(self.total_bytes),
                DisplayData::new(self.buf_size),
                self.concurrency
            )
        }
    }

    #[derive(Copy, Clone, Debug, PartialEq, Eq)]
    pub enum IoType {
        Read,
        Write,
    }

    #[derive(Copy, Clone, Debug, PartialEq, Eq)]
    pub enum IoPattern {
        Seq,
        Rnd,
    }
}

#[allow(non_upper_case_globals)]
mod consts {
    pub const B: usize = 1;

    pub const KiB: usize = 1024 * B;
    pub const MiB: usize = 1024 * KiB;
    pub const GiB: usize = 1024 * MiB;

    pub const KB: usize = 1000 * B;
    pub const MB: usize = 1000 * KB;
    pub const GB: usize = 1000 * MB;
}

#[allow(dead_code, temporary_cstring_as_ptr)]
mod disks {
    use super::*;
    use std::{ffi::CString, ops::Range};

    #[derive(Copy, Clone, Debug, PartialEq, Eq)]
    pub enum DiskType {
        SwornDisk,
        EncDisk,
    }

    pub trait BenchDisk: Send + Sync {
        fn read_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()>;
        fn write_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()>;

        fn read_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()>;
        fn write_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()>;

        // Methods with progress tracking
        fn read_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()>;
        fn write_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()>;
        fn read_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()>;
        fn write_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()>;
    }

    #[derive(Clone)]
    pub struct FileAsDisk {
        fd: i32,
        path: String,
        range: Range<BlockId>,
    }

    impl FileAsDisk {
        pub fn create(nblocks: usize, path: &str) -> Self {
            unsafe {
                // let oflag = O_RDWR | O_CREAT | O_TRUNC;
                let oflag = O_RDWR | O_CREAT | O_TRUNC | O_DIRECT;
                let fd = open(CString::new(path).unwrap().as_ptr() as _, oflag, 0o666);
                if fd == -1 {
                    println!("open error: {}", std::io::Error::last_os_error());
                }
                assert!(fd > 0);

                let res = ftruncate(fd, (nblocks * BLOCK_SIZE) as _);
                if res == -1 {
                    println!("ftruncate error: {}", std::io::Error::last_os_error());
                }
                assert!(res >= 0);

                Self {
                    fd,
                    path: path.to_string(),
                    range: 0..nblocks,
                }
            }
        }
    }

    impl BlockSet for FileAsDisk {
        fn read(&self, mut pos: BlockId, mut buf: BufMut) -> Result<()> {
            pos += self.range.start;
            debug_assert!(pos + buf.nblocks() <= self.range.end);

            let buf_mut_slice = buf.as_mut_slice();
            unsafe {
                let res = pread(
                    self.fd,
                    buf_mut_slice.as_ptr() as _,
                    buf_mut_slice.len(),
                    (pos * BLOCK_SIZE) as _,
                );
                if res == -1 {
                    return_errno_with_msg!(Errno::IoFailed, "file read failed");
                }
            }

            Ok(())
        }

        fn write(&self, mut pos: BlockId, buf: BufRef) -> Result<()> {
            pos += self.range.start;
            debug_assert!(pos + buf.nblocks() <= self.range.end);

            let buf_slice = buf.as_slice();
            unsafe {
                let res = pwrite(
                    self.fd,
                    buf_slice.as_ptr() as _,
                    buf_slice.len(),
                    (pos * BLOCK_SIZE) as _,
                );
                if res == -1 {
                    return_errno_with_msg!(Errno::IoFailed, "file write failed");
                }
            }

            Ok(())
        }

        fn subset(&self, range: Range<BlockId>) -> Result<Self>
        where
            Self: Sized,
        {
            debug_assert!(self.range.start + range.end <= self.range.end);
            Ok(Self {
                fd: self.fd,
                path: self.path.clone(),
                range: Range {
                    start: self.range.start + range.start,
                    end: self.range.start + range.end,
                },
            })
        }

        fn flush(&self) -> Result<()> {
            unsafe {
                let res = fdatasync(self.fd);
                if res == -1 {
                    return_errno_with_msg!(Errno::IoFailed, "file sync failed");
                }
            }
            Ok(())
        }

        fn nblocks(&self) -> usize {
            self.range.len()
        }
    }

    impl Drop for FileAsDisk {
        fn drop(&mut self) {
            unsafe {
                unlink(self.path.as_ptr() as _);
            }
        }
    }

    impl BenchDisk for SwornDisk<FileAsDisk> {
        fn read_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;

            for i in 0..total_nblocks / buf_nblocks {
                self.read(pos + i * buf_nblocks, buf.as_mut())?;
            }

            Ok(())
        }

        fn write_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;

            for i in 0..total_nblocks / buf_nblocks {
                self.write(pos + i * buf_nblocks, buf.as_ref())?;
            }

            self.sync()
        }

        fn read_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;

            for _ in 0..total_nblocks / buf_nblocks {
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.read(pos + rnd_pos, buf.as_mut())?;
            }

            Ok(())
        }

        fn write_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;

            for _ in 0..total_nblocks / buf_nblocks {
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.write(pos + rnd_pos, buf.as_ref())?;
            }

            self.sync()
        }

        fn read_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for i in 0..total_nblocks / buf_nblocks {
                self.read(pos + i * buf_nblocks, buf.as_mut())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            Ok(())
        }

        fn write_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for i in 0..total_nblocks / buf_nblocks {
                self.write(pos + i * buf_nblocks, buf.as_ref())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            self.sync()
        }

        fn read_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for _ in 0..total_nblocks / buf_nblocks {
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.read(pos + rnd_pos, buf.as_mut())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            Ok(())
        }

        fn write_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for _ in 0..total_nblocks / buf_nblocks {
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.write(pos + rnd_pos, buf.as_ref())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            self.sync()
        }
    }

    fn gen_rnd_pos(total_nblocks: usize, buf_nblocks: usize) -> BlockId {
        let mut rnd_pos_bytes = [0u8; 8];
        Rng::new(&[]).fill_bytes(&mut rnd_pos_bytes).unwrap();
        BlockId::from_le_bytes(rnd_pos_bytes) % (total_nblocks - buf_nblocks)
    }

    #[derive(Clone)]
    pub struct EncDisk {
        file_disk: FileAsDisk,
    }

    impl EncDisk {
        pub fn create(nblocks: usize, path: &str) -> Self {
            Self {
                file_disk: FileAsDisk::create(nblocks, path),
            }
        }

        fn dummy_encrypt() -> Result<()> {

            Ok(())
        }

        fn dummy_decrypt() -> Result<()> {

            Ok(())
        }
    }

    impl BenchDisk for EncDisk {
        fn read_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;

            for i in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_decrypt().unwrap();
                }
                self.file_disk.read(pos + i * buf_nblocks, buf.as_mut())?;
            }

            Ok(())
        }

        fn write_seq(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;

            for i in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_encrypt().unwrap();
                }
                self.file_disk.write(pos + i * buf_nblocks, buf.as_ref())?;
            }

            self.file_disk.flush()
        }

        fn read_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;

            for _ in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_decrypt().unwrap();
                }
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.file_disk.read(pos + rnd_pos, buf.as_mut())?;
            }

            Ok(())
        }

        fn write_rnd(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;

            for _ in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_encrypt().unwrap();
                }
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.file_disk.write(pos + rnd_pos, buf.as_ref())?;
            }

            self.file_disk.flush()
        }

        fn read_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for i in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_decrypt().unwrap();
                }
                self.file_disk.read(pos + i * buf_nblocks, buf.as_mut())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            Ok(())
        }

        fn write_seq_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for i in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_encrypt().unwrap();
                }
                self.file_disk.write(pos + i * buf_nblocks, buf.as_ref())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            self.file_disk.flush()
        }

        fn read_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let mut buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for _ in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_decrypt().unwrap();
                }
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.file_disk.read(pos + rnd_pos, buf.as_mut())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            Ok(())
        }

        fn write_rnd_with_progress(&self, pos: BlockId, total_nblocks: usize, buf_nblocks: usize, counter: Arc<AtomicU64>) -> Result<()> {
            let buf = Buf::alloc(buf_nblocks)?;
            let bytes_per_op = buf_nblocks * BLOCK_SIZE;

            for _ in 0..total_nblocks / buf_nblocks {
                for _ in 0..buf_nblocks {
                    Self::dummy_encrypt().unwrap();
                }
                let rnd_pos = gen_rnd_pos(total_nblocks, buf_nblocks);
                self.file_disk.write(pos + rnd_pos, buf.as_ref())?;
                counter.fetch_add(bytes_per_op as u64, Ordering::Relaxed);
            }

            self.file_disk.flush()
        }
    }
}

mod util {
    use super::*;
    use std::fmt::{self};
    use std::time::Duration;

    /// Display the amount of data in the unit of GiB, MiB, KiB, or bytes.
    #[derive(Copy, Clone, Debug, PartialEq, Eq)]
    pub struct DisplayData(usize);

    impl DisplayData {
        pub fn new(nbytes: usize) -> Self {
            Self(nbytes)
        }
    }

    impl fmt::Display for DisplayData {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            const UNIT_TABLE: [(&str, usize); 4] =
                [("GiB", GiB), ("MiB", MiB), ("KiB", KiB), ("bytes", 0)];
            let (unit_str, unit_val) = {
                let (unit_str, mut unit_val) = UNIT_TABLE
                    .iter()
                    .find(|(_, unit_val)| self.0 >= *unit_val)
                    .unwrap();
                if unit_val == 0 {
                    unit_val = 1;
                }
                (unit_str, unit_val)
            };
            let data_val_in_unit = (self.0 as f64) / (unit_val as f64);
            write!(f, "{:.1} {}", data_val_in_unit, unit_str)
        }
    }

    /// Display throughput in the unit of bytes/s, KB/s, MB/s, or GB/s.
    #[derive(Copy, Clone, Debug, PartialEq)]
    pub struct DisplayThroughput(f64);

    impl DisplayThroughput {
        pub fn new(total_bytes: usize, elapsed: Duration) -> Self {
            let total_bytes = total_bytes as f64;
            let elapsed_secs = elapsed.as_secs_f64();
            let throughput = total_bytes / elapsed_secs;
            Self(throughput)
        }
    }

    impl fmt::Display for DisplayThroughput {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            const UNIT_TABLE: [(&str, usize); 4] =
                [("GB/s", GB), ("MB/s", MB), ("KB/s", KB), ("bytes/s", 0)];
            let (unit_str, unit_val) = {
                let (unit_str, mut unit_val) = UNIT_TABLE
                    .iter()
                    .find(|(_, unit_val)| self.0 >= (*unit_val as f64))
                    .unwrap();
                if unit_val == 0 {
                    unit_val = 1;
                }
                (unit_str, unit_val)
            };
            let throughput_in_unit = self.0 / (unit_val as f64);
            write!(f, "{:.2} {}", throughput_in_unit, unit_str)
        }
    }
}
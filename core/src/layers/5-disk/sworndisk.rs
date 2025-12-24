//! SwornDisk as a block device.
//!
//! API: submit_bio(), submit_bio_sync(), create(), open(),
//! read(), readv(), write(), writev(), sync().
//!
//! Responsible for managing a `TxLsmTree`, whereas the TX logs (WAL and SSTs)
//! are stored; an untrusted disk storing user data, a `BlockAlloc` for managing data blocks'
//! allocation metadata. `TxLsmTree` and `BlockAlloc` are manipulated
//! based on internal transactions.
use super::bio::{BioReq, BioReqQueue, BioResp, BioType};
use super::block_alloc::{AllocTable, BlockAlloc};
use super::data_buf::DataBuf;
use super::dealloc_block::DeallocTable;
use super::gc::{
    GcWorker, ReverseKey, ReverseValue, SharedStateRef, VictimPolicy, VictimPolicyRef,
};
use crate::layers::bio::{BlockId, BlockSet, Buf, BufMut, BufRef, BLOCK_SIZE};
use crate::layers::disk::config::Config;
use crate::layers::disk::gc::{GreedyVictimPolicy, SharedState};
use crate::layers::disk::WAF_STATS;
use crate::layers::log::TxLogStore;
use crate::layers::lsm::{
    AsKV, LsmLevel, RangeQueryCtx, RecordKey as RecordK, RecordValue as RecordV, SyncIdStore,
    TxEventListener, TxEventListenerFactory, TxLsmTree, TxType,
};
use crate::os::{
    Aead, AeadIv as Iv, AeadKey as Key, AeadMac as Mac, BTreeMap, Condvar, CvarMutex, RwLock,
};
use crate::prelude::*;
use crate::tx::Tx;

use crate::{CostL3Type, COST_L2, COST_L3};
use core::cell::UnsafeCell;
use core::num::NonZeroUsize;
use core::ops::{Add, Sub};
use core::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU64, Ordering};
use lazy_static::lazy_static;
use pod::Pod;
use spin::Mutex;
use std::thread;
use time::Time;

/// Logical Block Address.
pub type Lba = BlockId;
/// Host Block Address.
pub type Hba = BlockId;

/// Wrapper for CONFIG that allows one-time initialization
pub struct ConfigCell {
    initialized: AtomicBool,
    value: UnsafeCell<Config>,
}

impl ConfigCell {
    pub fn new(config: Config) -> Self {
        ConfigCell {
            initialized: AtomicBool::new(false), // Start as uninitialized
            value: UnsafeCell::new(config),
        }
    }

    pub fn set(&self, config: Config) {
        // Only allow setting if not yet initialized
        if !self.initialized.swap(true, Ordering::SeqCst) {
            unsafe {
                *self.value.get() = config;
            }
            println!("CONFIG set successfully: cache_size={}", config.cache_size);
        } else {
            println!("CONFIG already initialized, ignoring new config");
        }
    }

    pub fn get(&self) -> &Config {
        unsafe { &*self.value.get() }
    }
}

unsafe impl Send for ConfigCell {}
unsafe impl Sync for ConfigCell {}

lazy_static! {
    /// The capacity of the data buffer.
    pub static ref CONFIG: ConfigCell = ConfigCell::new(Config::default());
}

/// SwornDisk.
pub struct SwornDisk<D: BlockSet> {
    inner: Arc<DiskInner<D>>,
}

/// Inner structures of `SwornDisk`.
struct DiskInner<D: BlockSet> {
    /// Block I/O request queue.
    bio_req_queue: BioReqQueue,
    /// A `TxLsmTree` to store metadata of the logical blocks.
    logical_block_table: TxLsmTree<RecordKey, RecordValue, D>,
    /// A reverse index table that map HBA to LBA.
    reverse_index_table: Option<TxLsmTree<ReverseKey, ReverseValue, D>>,
    /// A reverse index table that map HBA to LBA.
    dealloc_table: Arc<DeallocTable>,
    /// The underlying disk where user data is stored.
    user_data_disk: Arc<D>,
    /// Manage space of the data disk.
    block_validity_table: Arc<AllocTable>,
    /// TX log store for managing logs in `TxLsmTree` and block alloc logs.
    tx_log_store: Arc<TxLogStore<D>>,
    /// A buffer to cache data blocks.
    data_buf: DataBuf,
    /// Root encryption key.
    root_key: Key,
    /// Whether `SwornDisk` is dropped.
    is_dropped: AtomicBool,
    /// Scope lock for control write and sync operation.
    write_sync_region: RwLock<()>,
    /// Shared state for background GC.
    shared_state: SharedStateRef,
    /// Whether the disk is active.
    is_active: Arc<AtomicBool>,
}

impl<D: BlockSet + 'static> SwornDisk<D> {
    /// Read a specified number of blocks at a logical block address on the device.
    /// The block contents will be read into a single contiguous buffer.
    pub fn read(&self, lba: Lba, buf: BufMut) -> Result<()> {
        self.check_rw_args(lba, buf.nblocks())?;
        self.inner.read(lba, buf)
    }

    /// Read multiple blocks at a logical block address on the device.
    /// The block contents will be read into several scattered buffers.
    pub fn readv<'a>(&self, lba: Lba, bufs: &'a mut [BufMut<'a>]) -> Result<()> {
        self.check_rw_args(lba, bufs.iter().fold(0, |acc, buf| acc + buf.nblocks()))?;
        self.inner.readv(lba, bufs)
    }

    /// Write a specified number of blocks at a logical block address on the device.
    /// The block contents reside in a single contiguous buffer.
    pub fn write(&self, lba: Lba, buf: BufRef) -> Result<()> {
        self.check_rw_args(lba, buf.nblocks())?;
        let _rguard = self.inner.write_sync_region.read();
        self.inner.write(lba, buf)
    }

    /// Write multiple blocks at a logical block address on the device.
    /// The block contents reside in several scattered buffers.
    pub fn writev(&self, lba: Lba, bufs: &[BufRef]) -> Result<()> {
        self.check_rw_args(lba, bufs.iter().fold(0, |acc, buf| acc + buf.nblocks()))?;
        let _rguard = self.inner.write_sync_region.read();
        self.inner.writev(lba, bufs)
    }

    /// Sync all cached data in the device to the storage medium for durability.
    pub fn sync(&self) -> Result<()> {
        let _wguard = self.inner.write_sync_region.write();
        // TODO: Error handling the sync operation
        self.inner.sync().unwrap();

        #[cfg(not(feature = "linux"))]
        trace!("[SwornDisk] Sync completed. {self:?}");
        Ok(())
    }

    /// Returns the total number of blocks in the device.
    pub fn total_blocks(&self) -> usize {
        self.inner.user_data_disk.nblocks()
    }

    /// Creates a new `SwornDisk` on the given disk, with the root encryption key.
    pub fn create(
        disk: D,
        root_key: Key,
        sync_id_store: Option<Arc<dyn SyncIdStore>>,
        config: Option<Config>,
        enable_gc: bool,
        victim_policy_ref: Option<VictimPolicyRef>,
    ) -> Result<Self> {
        if let Some(cfg) = config {
            CONFIG.set(cfg);
        }

        let data_disk = Self::subdisk_for_data(&disk)?;
        let lsm_tree_disk = Self::subdisk_for_logical_block_table(&disk)?;
        let reverse_index_disk = Self::subdisk_for_reverse_index_table(&disk)?;
        let tx_log_store = Arc::new(TxLogStore::format(lsm_tree_disk, root_key.clone())?);
        let block_validity_table = Arc::new(AllocTable::new(
            NonZeroUsize::new(data_disk.nblocks()).unwrap(),
        ));

        let shared_state = Arc::new(SharedState::new());

        let (dealloc_table, reverse_index_table) = if enable_gc {
            let reverse_index_tx_log_store =
                Arc::new(TxLogStore::format(reverse_index_disk, root_key.clone())?);
            (
                Arc::new(DeallocTable::new(
                    NonZeroUsize::new(data_disk.nblocks()).unwrap(),
                )),
                Some(TxLsmTree::format(
                    reverse_index_tx_log_store,
                    Arc::new(EmptyFactory),
                    None,
                    sync_id_store.clone(),
                    shared_state.clone(),
                )?),
            )
        } else {
            (
                Arc::new(DeallocTable::new(
                    NonZeroUsize::new(data_disk.nblocks()).unwrap(),
                )),
                None,
            )
        };

        let listener_factory = Arc::new(TxLsmTreeListenerFactory::new(
            tx_log_store.clone(),
            block_validity_table.clone(),
            dealloc_table.clone(),
        ));

        let logical_block_table = {
            let table = block_validity_table.clone();
            let dealloc_table = dealloc_table.clone();
            let on_drop_record_in_memtable = move |record: &dyn AsKV<RecordKey, RecordValue>| {
                // Deallocate the host block while the corresponding record is dropped in `MemTable`
                if dealloc_table.has_deallocated(record.value().hba) {
                    dealloc_table.finish_deallocated(record.value().hba);
                    return;
                }
                table.set_deallocated(record.value().hba);
            };
            TxLsmTree::format(
                tx_log_store.clone(),
                listener_factory,
                Some(Arc::new(on_drop_record_in_memtable)),
                sync_id_store,
                shared_state.clone(),
            )?
        };

        let inner = Arc::new(DiskInner {
            bio_req_queue: BioReqQueue::new(),
            logical_block_table,
            reverse_index_table,
            dealloc_table,
            user_data_disk: Arc::new(data_disk),
            block_validity_table,
            tx_log_store,
            data_buf: DataBuf::new(DATA_BUF_CAP),
            root_key,
            is_dropped: AtomicBool::new(false),
            write_sync_region: RwLock::new(()),
            shared_state,
            is_active: Arc::new(AtomicBool::new(true)),
        });
        if enable_gc {
            let gc_worker = match victim_policy_ref {
                Some(policy_ref) => inner.create_gc_worker(policy_ref)?,
                None => {
                    // use GreedyVictimPolicy by default
                    let policy = Arc::new(GreedyVictimPolicy {});
                    inner.create_gc_worker(policy)?
                }
            };
            thread::spawn(move || gc_worker.run());
        }

        let new_self = Self { inner };

        #[cfg(not(feature = "linux"))]
        info!("[SwornDisk] Created successfully! {:?}", &new_self);
        // XXX: Would `disk::drop()` bring unexpected behavior?
        Ok(new_self)
    }

    /// Opens the `SwornDisk` on the given disk, with the root encryption key.
    pub fn open(
        disk: D,
        root_key: Key,
        victim_policy_ref: Option<VictimPolicyRef>,
        sync_id_store: Option<Arc<dyn SyncIdStore>>,
        config: Option<Config>,
        enable_gc: bool,
    ) -> Result<Self> {
        if let Some(cfg) = config {
            CONFIG.set(cfg);
        }

        let data_disk = Self::subdisk_for_data(&disk)?;
        let lsm_tree_disk = Self::subdisk_for_logical_block_table(&disk)?;

        let tx_log_store = Arc::new(TxLogStore::recover(lsm_tree_disk, root_key)?);
        let block_validity_table = Arc::new(AllocTable::recover(
            NonZeroUsize::new(data_disk.nblocks()).unwrap(),
            &tx_log_store,
        )?);

        let shared_state = Arc::new(SharedState::new());

        let (dealloc_table, reverse_index_table) = if enable_gc {
            (
                Arc::new(DeallocTable::new(
                    NonZeroUsize::new(data_disk.nblocks()).unwrap(),
                )),
                Some(TxLsmTree::format(
                    tx_log_store.clone(),
                    Arc::new(EmptyFactory),
                    None,
                    sync_id_store.clone(),
                    shared_state.clone(),
                )?),
            )
        } else {
            (
                Arc::new(DeallocTable::new(
                    NonZeroUsize::new(data_disk.nblocks()).unwrap(),
                )),
                None,
            )
        };
        let listener_factory = Arc::new(TxLsmTreeListenerFactory::new(
            tx_log_store.clone(),
            block_validity_table.clone(),
            dealloc_table.clone(),
        ));

        let logical_block_table = {
            let table = block_validity_table.clone();
            let rit = dealloc_table.clone();
            let on_drop_record_in_memtable = move |record: &dyn AsKV<RecordKey, RecordValue>| {
                //  Deallocate the host block while the corresponding record is dropped in `MemTable`
                if rit.has_deallocated(record.value().hba) {
                    rit.finish_deallocated(record.value().hba);
                    return;
                }
                table.set_deallocated(record.value().hba);
            };
            TxLsmTree::recover(
                tx_log_store.clone(),
                listener_factory,
                Some(Arc::new(on_drop_record_in_memtable)),
                sync_id_store,
                shared_state.clone(),
            )?
        };

        let inner = Arc::new(DiskInner {
            bio_req_queue: BioReqQueue::new(),
            logical_block_table,
            reverse_index_table,
            dealloc_table,
            user_data_disk: Arc::new(data_disk),
            block_validity_table,
            data_buf: DataBuf::new(DATA_BUF_CAP),
            tx_log_store,
            root_key,
            is_dropped: AtomicBool::new(false),
            write_sync_region: RwLock::new(()),
            shared_state,
            is_active: Arc::new(AtomicBool::new(true)),
        });

        if enable_gc {
            let gc_worker = match victim_policy_ref {
                Some(policy_ref) => inner.create_gc_worker(policy_ref)?,
                None => {
                    // use GreedyVictimPolicy by default
                    let policy = Arc::new(GreedyVictimPolicy {});
                    inner.create_gc_worker(policy)?
                }
            };
            thread::spawn(move || gc_worker.run());
        }

        let opened_self = Self { inner };

        #[cfg(not(feature = "linux"))]
        info!("[SwornDisk] Opened successfully! {:?}", &opened_self);
        Ok(opened_self)
    }

    /// Submit a new block I/O request and wait its completion (Synchronous).
    pub fn submit_bio_sync(&self, bio_req: BioReq) -> BioResp {
        bio_req.submit();
        self.inner.handle_bio_req(&bio_req)
    }
    // TODO: Support handling request asynchronously

    /// Check whether the arguments are valid for read/write operations.
    fn check_rw_args(&self, lba: Lba, buf_nblocks: usize) -> Result<()> {
        if lba + buf_nblocks > self.inner.user_data_disk.nblocks() {
            Err(Error::with_msg(
                OutOfDisk,
                "read/write out of disk capacity",
            ))
        } else {
            Ok(())
        }
    }

    fn subdisk_for_data(disk: &D) -> Result<D> {
        disk.subset(0..disk.nblocks() * 15 / 16) // TBD
    }

    fn subdisk_for_logical_block_table(disk: &D) -> Result<D> {
        disk.subset(disk.nblocks() * 15 / 16..disk.nblocks() * 31 / 32) // TBD
    }

    fn subdisk_for_reverse_index_table(disk: &D) -> Result<D> {
        disk.subset(disk.nblocks() * 31 / 32..disk.nblocks()) // TBD
    }

    // Create a gc worker but not launch, just for test
    #[cfg(test)]
    #[allow(private_interfaces)]
    pub fn create_gc_worker(&self, policy_ref: VictimPolicyRef) -> Result<GcWorker<D>> {
        use super::gc::VictimPolicyRef;

        self.inner.create_gc_worker(policy_ref)
    }
}

/// Capacity of the user data blocks buffer.
const DATA_BUF_CAP: usize = 1024;

impl<D: BlockSet + 'static> DiskInner<D> {
    /// Read a specified number of blocks at a logical block address on the device.
    /// The block contents will be read into a single contiguous buffer.
    pub fn read(&self, lba: Lba, buf: BufMut) -> Result<()> {
        let nblocks = buf.nblocks();

        let res = if nblocks == 1 {
            self.read_one_block(lba, buf)
        } else {
            self.read_multi_blocks(lba, &mut [buf])
        };

        // Allow empty read
        if let Err(e) = &res
            && e.errno() == NotFound
        {
            #[cfg(not(feature = "linux"))]
            warn!("[SwornDisk] read contains empty read on lba {lba}");
            return Ok(());
        }
        res
    }

    /// Read multiple blocks at a logical block address on the device.
    /// The block contents will be read into several scattered buffers.
    pub fn readv<'a>(&self, lba: Lba, bufs: &'a mut [BufMut<'a>]) -> Result<()> {
        let res = self.read_multi_blocks(lba, bufs);

        // Allow empty read
        if let Err(e) = &res
            && e.errno() == NotFound
        {
            #[cfg(not(feature = "linux"))]
            warn!("[SwornDisk] readv contains empty read on lba {lba}");
            return Ok(());
        }
        res
    }

    fn read_one_block(&self, lba: Lba, mut buf: BufMut) -> Result<()> {
        debug_assert_eq!(buf.nblocks(), 1);
        // Search in `DataBuf` first
        if self.data_buf.get(RecordKey { lba }, &mut buf).is_some() {
            return Ok(());
        }

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::LogicalBlockTable))
        } else {
            None
        };
        self.wait_for_background_gc();
        // Search in `TxLsmTree` then
        let value = self.logical_block_table.get(&RecordKey { lba })?;
        drop(timer);

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::BlockIO))
        } else {
            None
        };
        let mut cipher = Buf::alloc(1)?;
        self.user_data_disk.read(value.hba, cipher.as_mut())?;
        drop(timer);

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::Encryption))
        } else {
            None
        };
        Aead::new().decrypt(
            cipher.as_slice(),
            &value.key,
            &Iv::new_zeroed(),
            &[],
            &value.mac,
            buf.as_mut_slice(),
        )?;
        drop(timer);

        Ok(())
    }

    fn read_multi_blocks<'a>(&self, lba: Lba, bufs: &'a mut [BufMut<'a>]) -> Result<()> {
        let mut buf_vec = BufMutVec::from_bufs(bufs);
        let nblocks = buf_vec.nblocks();

        let mut range_query_ctx =
            RangeQueryCtx::<RecordKey, RecordValue>::new(RecordKey { lba }, nblocks);

        // Search in `DataBuf` first
        for (key, data_block) in self
            .data_buf
            .get_range(range_query_ctx.range_uncompleted().unwrap())
        {
            buf_vec
                .nth_buf_mut_slice(key.lba - lba)
                .copy_from_slice(data_block.as_slice());
            range_query_ctx.mark_completed(key);
        }
        if range_query_ctx.is_completed() {
            return Ok(());
        }
        self.wait_for_background_gc();

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::LogicalBlockTable))
        } else {
            None
        };
        // Search in `TxLsmTree` then
        self.logical_block_table.get_range(&mut range_query_ctx)?;
        drop(timer);
        // Allow empty read
        debug_assert!(range_query_ctx.is_completed());

        let mut res = range_query_ctx.into_results();
        let record_batches = {
            res.sort_by(|(_, v1), (_, v2)| v1.hba.cmp(&v2.hba));
            res.group_by(|(_, v1), (_, v2)| v2.hba - v1.hba == 1)
        };

        // Perform disk read in batches and decryption
        let mut cipher_buf = Buf::alloc(nblocks)?;
        let cipher_slice = cipher_buf.as_mut_slice();
        for record_batch in record_batches {
            let timer = if CONFIG.get().stat_cost {
                Some(COST_L3.time(CostL3Type::BlockIO))
            } else {
                None
            };
            self.user_data_disk.read(
                record_batch.first().unwrap().1.hba,
                BufMut::try_from(&mut cipher_slice[..record_batch.len() * BLOCK_SIZE]).unwrap(),
            )?;
            drop(timer);

            let timer = if CONFIG.get().stat_cost {
                Some(COST_L3.time(CostL3Type::Encryption))
            } else {
                None
            };
            for (nth, (key, value)) in record_batch.iter().enumerate() {
                Aead::new().decrypt(
                    &cipher_slice[nth * BLOCK_SIZE..(nth + 1) * BLOCK_SIZE],
                    &value.key,
                    &Iv::new_zeroed(),
                    &[],
                    &value.mac,
                    buf_vec.nth_buf_mut_slice(key.lba - lba),
                )?;
            }
            drop(timer);
        }

        Ok(())
    }

    /// Write a specified number of blocks at a logical block address on the device.
    /// The block contents reside in a single contiguous buffer.
    pub fn write(&self, mut lba: Lba, buf: BufRef) -> Result<()> {
        // WAF Statistics: count all user write calls as logical writes
        if CONFIG.get().stat_waf {
            WAF_STATS.add_logical(buf.as_slice().len() as u64);
        }

        // Write block contents to `DataBuf` directly
        for block_buf in buf.iter() {
            let buf_at_capacity = self.data_buf.put(RecordKey { lba }, block_buf);

            // Flush all data blocks in `DataBuf` to disk if it's full
            if buf_at_capacity {
                // TODO: Error handling: Should discard current write in `DataBuf`
                // flush_data_buf will wait for background GC to finish
                self.flush_data_buf()?;
            }
            lba += 1;
        }
        Ok(())
    }

    /// Write multiple blocks at a logical block address on the device.
    /// The block contents reside in several scattered buffers.
    pub fn writev(&self, mut lba: Lba, bufs: &[BufRef]) -> Result<()> {
        for buf in bufs {
            self.write(lba, *buf)?;
            lba += buf.nblocks();
        }
        Ok(())
    }

    fn flush_data_buf(&self) -> Result<()> {
        self.wait_for_background_gc();

        let mut ret = self.write_blocks_from_data_buf();

        if let Err(e) = ret.as_ref() {
            if e.errno() == OutOfDisk {
                self.logical_block_table.manual_compaction()?;
                // try write again
                ret = self.write_blocks_from_data_buf();
            }
        }

        let records = ret?;

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::LogicalBlockTable))
        } else {
            None
        };
        // Insert new records of data blocks to `TxLsmTree`
        for (key, value) in records.iter() {
            if !CONFIG.get().delayed_reclamation {
                // ignore this error
                let _ = self.logical_block_table.get(&key);
            }
            // TODO: Error handling: Should dealloc the written blocks
            self.logical_block_table.put(key.clone(), value.clone())?;
            if let Some(reverse_index_table) = &self.reverse_index_table {
                let reverse_index_key = ReverseKey { hba: value.hba };
                let reverse_index_value = ReverseValue { lba: key.lba };
                reverse_index_table.put(reverse_index_key, reverse_index_value)?;
            }
        }

        drop(timer);
        self.is_active.store(true, Ordering::Release);
        self.data_buf.clear();
        Ok(())
    }

    fn write_blocks_from_data_buf(&self) -> Result<Vec<(RecordKey, RecordValue)>> {
        let data_blocks = self.data_buf.all_blocks();

        let num_write = data_blocks.len();
        let mut records = Vec::with_capacity(num_write);
        if num_write == 0 {
            return Ok(records);
        }
        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::Allocation))
        } else {
            None
        };
        // Allocate slots for data blocks
        let hbas = self
            .block_validity_table
            .alloc_batch(NonZeroUsize::new(num_write).unwrap())?;
        debug_assert_eq!(hbas.len(), num_write);
        drop(timer);
        let hba_batches = hbas.group_by(|hba1, hba2| hba2 - hba1 == 1);

        // Perform encryption and batch disk write
        let mut cipher_buf = Buf::alloc(num_write)?;
        let mut cipher_slice = cipher_buf.as_mut_slice();
        let mut nth = 0;
        for hba_batch in hba_batches {
            let timer = if CONFIG.get().stat_cost {
                Some(COST_L3.time(CostL3Type::Encryption))
            } else {
                None
            };
            for (i, &hba) in hba_batch.iter().enumerate() {
                let (lba, data_block) = &data_blocks[nth];
                let key = Key::random();
                let mac = Aead::new().encrypt(
                    data_block.as_slice(),
                    &key,
                    &Iv::new_zeroed(),
                    &[],
                    &mut cipher_slice[i * BLOCK_SIZE..(i + 1) * BLOCK_SIZE],
                )?;

                records.push((*lba, RecordValue { hba, key, mac }));
                nth += 1;
            }
            drop(timer);

            let timer = if CONFIG.get().stat_cost {
                Some(COST_L3.time(CostL3Type::BlockIO))
            } else {
                None
            };
            self.user_data_disk.write(
                *hba_batch.first().unwrap(),
                BufRef::try_from(&cipher_slice[..hba_batch.len() * BLOCK_SIZE]).unwrap(),
            )?;
            drop(timer);
            cipher_slice = &mut cipher_slice[hba_batch.len() * BLOCK_SIZE..];
        }

        Ok(records)
    }

    /// Sync all cached data in the device to the storage medium for durability.
    pub fn sync(&self) -> Result<()> {
        // flush_data_buf will wait for background GC to finish
        self.flush_data_buf()?;
        debug_assert!(self.data_buf.is_empty());

        // self.logical_block_table.sync()?;

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::Allocation))
        } else {
            None
        };
        // XXX: May impact performance when there comes frequent syncs
        self.block_validity_table
            .do_compaction(&self.tx_log_store)?;
        drop(timer);

        self.tx_log_store.sync()?;

        let timer = if CONFIG.get().stat_cost {
            Some(COST_L3.time(CostL3Type::BlockIO))
        } else {
            None
        };
        self.user_data_disk.flush()?;
        drop(timer);
        Ok(())
    }

    /// Handle one block I/O request. Mark the request completed when finished,
    /// return any error that occurs.
    pub fn handle_bio_req(&self, req: &BioReq) -> BioResp {
        let res = match req.type_() {
            BioType::Read => self.do_read(&req),
            BioType::Write => self.do_write(&req),
            BioType::Sync => self.do_sync(&req),
        };

        req.complete(res.clone());
        res
    }

    pub fn create_gc_worker(&self, policy_ref: VictimPolicyRef) -> Result<GcWorker<D>> {
        // Safety: `reverse_index_table` is not None when enable_gc is true
        let gc_worker = GcWorker::new(
            policy_ref,
            self.logical_block_table.clone(),
            self.reverse_index_table.clone().unwrap(),
            self.dealloc_table.clone(),
            self.tx_log_store.clone(),
            self.block_validity_table.clone(),
            self.user_data_disk.clone(),
            self.shared_state.clone(),
            self.is_active.clone(),
        );
        Ok(gc_worker)
    }

    /// Handle a read I/O request.
    fn do_read(&self, req: &BioReq) -> BioResp {
        debug_assert_eq!(req.type_(), BioType::Read);

        let lba = req.addr() as Lba;
        let mut req_bufs = req.take_bufs();
        let mut bufs = {
            let mut bufs = Vec::with_capacity(req.nbufs());
            for buf in req_bufs.iter_mut() {
                bufs.push(BufMut::try_from(buf.as_mut_slice())?);
            }
            bufs
        };

        if bufs.len() == 1 {
            let buf = bufs.remove(0);
            return self.read(lba, buf);
        }

        self.readv(lba, &mut bufs)
    }

    /// Handle a write I/O request.
    fn do_write(&self, req: &BioReq) -> BioResp {
        debug_assert_eq!(req.type_(), BioType::Write);

        let lba = req.addr() as Lba;
        let req_bufs = req.take_bufs();
        let bufs = {
            let mut bufs = Vec::with_capacity(req.nbufs());
            for buf in req_bufs.iter() {
                bufs.push(BufRef::try_from(buf.as_slice())?);
            }
            bufs
        };

        self.writev(lba, &bufs)
    }

    /// Handle a sync I/O request.
    fn do_sync(&self, req: &BioReq) -> BioResp {
        debug_assert_eq!(req.type_(), BioType::Sync);
        self.sync()
    }

    // TODO: Currently, Background GC will block foreground I/O requests, but background gc will be launched when some foreground I/O requests remain running.
    // this might cause some issue

    // GcWorker will touch block_validity_table, logical_block_table and reverse_index_table and user_data_disk.
    // In the stop the world manner. to maximize the concurrency, we should call this function after accessing data_buf and before accessing these data structures.
    // To simplify the implementation, we should only call this function in some fn related to accessing these data structures directly.
    // E.g. fn flush_data_buf(), read_one_block(), read_multi_blocks()
    fn wait_for_background_gc(&self) {
        self.shared_state.wait_for_background_gc();
    }
}

impl<D: BlockSet> Drop for SwornDisk<D> {
    fn drop(&mut self) {
        self.inner.is_dropped.store(true, Ordering::Release);
    }
}

impl<D: BlockSet + 'static> Debug for SwornDisk<D> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SwornDisk")
            .field("user_data_nblocks", &self.inner.user_data_disk.nblocks())
            .field("logical_block_table", &self.inner.logical_block_table)
            .finish()
    }
}

/// A wrapper for `[BufMut]` used in `readv()`.
struct BufMutVec<'a> {
    bufs: &'a mut [BufMut<'a>],
    nblocks: usize,
}

impl<'a> BufMutVec<'a> {
    pub fn from_bufs(bufs: &'a mut [BufMut<'a>]) -> Self {
        debug_assert!(bufs.len() > 0);
        let nblocks = bufs
            .iter()
            .map(|buf| buf.nblocks())
            .fold(0_usize, |sum, nblocks| sum.saturating_add(nblocks));
        Self { bufs, nblocks }
    }

    pub fn nblocks(&self) -> usize {
        self.nblocks
    }

    pub fn nth_buf_mut_slice(&mut self, mut nth: usize) -> &mut [u8] {
        debug_assert!(nth < self.nblocks);
        for buf in self.bufs.iter_mut() {
            let nblocks = buf.nblocks();
            if nth >= buf.nblocks() {
                nth -= nblocks;
            } else {
                return &mut buf.as_mut_slice()[nth * BLOCK_SIZE..(nth + 1) * BLOCK_SIZE];
            }
        }
        &mut []
    }
}

// SAFETY: `SwornDisk` is concurrency-safe.
unsafe impl<D: BlockSet> Send for DiskInner<D> {}
unsafe impl<D: BlockSet> Sync for DiskInner<D> {}

/// Listener factory for `TxLsmTree`.
struct TxLsmTreeListenerFactory<D> {
    store: Arc<TxLogStore<D>>,
    alloc_table: Arc<AllocTable>,
    dealloc_table: Arc<DeallocTable>,
}

impl<D> TxLsmTreeListenerFactory<D> {
    fn new(
        store: Arc<TxLogStore<D>>,
        alloc_table: Arc<AllocTable>,
        reverse_index_table: Arc<DeallocTable>,
    ) -> Self {
        Self {
            store,
            alloc_table,
            dealloc_table: reverse_index_table,
        }
    }
}

impl<D: BlockSet + 'static> TxEventListenerFactory<RecordKey, RecordValue>
    for TxLsmTreeListenerFactory<D>
{
    fn new_event_listener(
        &self,
        tx_type: TxType,
    ) -> Arc<dyn TxEventListener<RecordKey, RecordValue>> {
        Arc::new(TxLsmTreeListener::new(
            tx_type,
            Arc::new(BlockAlloc::new(
                self.alloc_table.clone(),
                self.store.clone(),
            )),
            self.dealloc_table.clone(),
        ))
    }
}

struct EmptyFactory;
struct EmptyListener;

impl<K, V> TxEventListenerFactory<K, V> for EmptyFactory {
    fn new_event_listener(&self, _tx_type: TxType) -> Arc<dyn TxEventListener<K, V>> {
        Arc::new(EmptyListener)
    }
}
impl<K, V> TxEventListener<K, V> for EmptyListener {
    fn on_add_record(&self, _record: &dyn AsKV<K, V>) -> Result<()> {
        Ok(())
    }
    fn on_drop_record(&self, _record: &dyn AsKV<K, V>) -> Result<()> {
        Ok(())
    }
    fn on_tx_begin(&self, _tx: &mut Tx) -> Result<()> {
        Ok(())
    }
    fn on_tx_precommit(&self, _tx: &mut Tx) -> Result<()> {
        Ok(())
    }
    fn on_tx_commit(&self) {}
}

/// Event listener for `TxLsmTree`.
struct TxLsmTreeListener<D> {
    tx_type: TxType,
    block_alloc: Arc<BlockAlloc<D>>,
    dealloc_table: Arc<DeallocTable>,
}

impl<D> TxLsmTreeListener<D> {
    fn new(
        tx_type: TxType,
        block_alloc: Arc<BlockAlloc<D>>,
        reverse_index_table: Arc<DeallocTable>,
    ) -> Self {
        Self {
            tx_type,
            block_alloc,
            dealloc_table: reverse_index_table,
        }
    }
}

/// Register callbacks for different TXs in `TxLsmTree`.
impl<D: BlockSet + 'static> TxEventListener<RecordKey, RecordValue> for TxLsmTreeListener<D> {
    fn on_add_record(&self, record: &dyn AsKV<RecordKey, RecordValue>) -> Result<()> {
        match self.tx_type {
            TxType::Compaction { to_level } if to_level == LsmLevel::L0 => {
                self.block_alloc.alloc_block(record.value().hba)
            }
            // Major Compaction TX and Migration TX do not add new records
            TxType::Compaction { .. } | TxType::Migration => {
                // Do nothing
                Ok(())
            }
        }
    }

    fn on_drop_record(&self, record: &dyn AsKV<RecordKey, RecordValue>) -> Result<()> {
        match self.tx_type {
            // Minor Compaction TX doesn't compact records
            TxType::Compaction { to_level } if to_level == LsmLevel::L0 => {
                unreachable!();
            }
            TxType::Compaction { .. } | TxType::Migration => {
                if self.dealloc_table.has_deallocated(record.value().hba) {
                    self.dealloc_table.finish_deallocated(record.value().hba);
                    return Ok(());
                }
                self.block_alloc.dealloc_block(record.value().hba)
            }
        }
    }

    fn on_tx_begin(&self, tx: &mut Tx) -> Result<()> {
        match self.tx_type {
            TxType::Compaction { .. } | TxType::Migration => {
                tx.context(|| self.block_alloc.prepare_diff_log().unwrap())
            }
        }
        Ok(())
    }

    fn on_tx_precommit(&self, tx: &mut Tx) -> Result<()> {
        match self.tx_type {
            TxType::Compaction { .. } | TxType::Migration => {
                tx.context(|| self.block_alloc.update_diff_log().unwrap())
            }
        }
        Ok(())
    }

    fn on_tx_commit(&self) {
        match self.tx_type {
            TxType::Compaction { .. } | TxType::Migration => self.block_alloc.update_alloc_table(),
        }
    }
}

/// Key-Value record for `TxLsmTree`.
pub(super) struct Record {
    key: RecordKey,
    value: RecordValue,
}

/// The key of a `Record`.
#[repr(C)]
#[derive(Clone, Copy, Pod, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub(super) struct RecordKey {
    /// Logical block address of user data block.
    pub lba: Lba,
}

/// The value of a `Record`.
#[repr(C)]
#[derive(Clone, Copy, Pod, Debug)]
pub(super) struct RecordValue {
    /// Host block address of user data block.
    pub hba: Hba,
    /// Encryption key of the data block.
    pub key: Key,
    /// Encrypted MAC of the data block.
    pub mac: Mac,
}

impl Add<usize> for RecordKey {
    type Output = Self;

    fn add(self, other: usize) -> Self::Output {
        Self {
            lba: self.lba + other,
        }
    }
}

impl Sub<RecordKey> for RecordKey {
    type Output = usize;

    fn sub(self, other: RecordKey) -> Self::Output {
        self.lba - other.lba
    }
}

impl RecordK<RecordKey> for RecordKey {}
impl RecordV for RecordValue {}

impl AsKV<RecordKey, RecordValue> for Record {
    fn key(&self) -> &RecordKey {
        &self.key
    }

    fn value(&self) -> &RecordValue {
        &self.value
    }
}

#[cfg(feature = "occlum")]
mod impl_block_device {
    use super::{BlockSet, BufMut, BufRef, SwornDisk, Vec};
    use ext2_rs::{Bid, BlockDevice, FsError as Ext2Error};

    impl<D: BlockSet + 'static> BlockDevice for SwornDisk<D> {
        fn total_blocks(&self) -> usize {
            self.total_blocks()
        }

        fn read_blocks(&self, bid: Bid, blocks: &mut [&mut [u8]]) -> Result<(), Ext2Error> {
            if blocks.len() == 1 {
                self.read(
                    bid as _,
                    BufMut::try_from(blocks.first_mut().unwrap().as_mut()).unwrap(),
                )?;
                return Ok(());
            }

            let mut bufs = blocks
                .iter_mut()
                .map(|block| BufMut::try_from(block.as_mut()).unwrap())
                .collect::<Vec<_>>();
            self.readv(bid as _, &mut bufs)?;
            Ok(())
        }

        fn write_blocks(&self, bid: Bid, blocks: &[&[u8]]) -> Result<(), Ext2Error> {
            if blocks.len() == 1 {
                self.write(
                    bid as _,
                    BufRef::try_from(blocks.first().unwrap().as_ref()).unwrap(),
                )?;
                return Ok(());
            }

            let bufs = blocks
                .iter()
                .map(|block| BufRef::try_from(block.as_ref()).unwrap())
                .collect::<Vec<_>>();
            self.writev(bid as _, &bufs)?;
            Ok(())
        }

        fn sync(&self) -> Result<(), Ext2Error> {
            self.sync()?;
            Ok(())
        }
    }

    impl From<crate::Error> for Ext2Error {
        fn from(value: crate::Error) -> Self {
            match value.errno() {
                crate::Errno::NotFound => Self::EntryNotFound,
                crate::Errno::InvalidArgs => Self::InvalidParam,
                crate::Errno::OutOfDisk => Self::NoDeviceSpace,
                crate::Errno::PermissionDenied => Self::PermError,
                _ => {
                    log::error!("[SwornDisk] Error occurred: {value:?}");
                    Self::DeviceError(0)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layers::bio::MemDisk;
    use crate::layers::disk::bio::{BioReqBuilder, BlockBuf};

    use core::ptr::NonNull;
    use std::thread;

    #[test]
    fn sworndisk_fns() -> Result<()> {
        let nblocks = 128 * 1024;
        let mem_disk = MemDisk::create(nblocks)?;
        let root_key = Key::random();
        // Create a new `SwornDisk` then do some writes
        let sworndisk = SwornDisk::create(mem_disk.clone(), root_key, None, None, false, None)?;
        let num_rw = 1024;

        // // Submit a write block I/O request
        let mut wbuf = Buf::alloc(num_rw)?;
        let bufs = {
            let mut bufs = Vec::with_capacity(num_rw);
            for i in 0..num_rw {
                let buf_slice = &mut wbuf.as_mut_slice()[i * BLOCK_SIZE..(i + 1) * BLOCK_SIZE];
                buf_slice.fill(i as u8);
                bufs.push(unsafe {
                    BlockBuf::from_raw_parts(
                        NonNull::new(buf_slice.as_mut_ptr()).unwrap(),
                        BLOCK_SIZE,
                    )
                });
            }
            bufs
        };
        let bio_req = BioReqBuilder::new(BioType::Write)
            .addr(0 as BlockId)
            .bufs(bufs)
            .build();
        sworndisk.submit_bio_sync(bio_req)?;

        // // Sync the `SwornDisk` then do some reads
        sworndisk.submit_bio_sync(BioReqBuilder::new(BioType::Sync).build())?;

        let mut rbuf = Buf::alloc(1)?;
        for i in 0..num_rw {
            sworndisk.read(i as Lba, rbuf.as_mut())?;
            assert_eq!(rbuf.as_slice()[0], i as u8);
        }

        // Open the closed `SwornDisk` then test its data's existence
        drop(sworndisk);
        thread::spawn(move || -> Result<()> {
            let opened_sworndisk = SwornDisk::open(mem_disk, root_key, None, None, false, None)?;
            let mut rbuf = Buf::alloc(2)?;
            opened_sworndisk.read(5 as Lba, rbuf.as_mut())?;
            assert_eq!(rbuf.as_slice()[0], 5u8);
            assert_eq!(rbuf.as_slice()[4096], 6u8);
            Ok(())
        })
        .join()
        .unwrap()
    }
}

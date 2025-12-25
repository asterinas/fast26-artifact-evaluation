//! Block allocation.
use super::segment::{self, recover_segment_table, Segment, SegmentId, SEGMENT_SIZE};
use super::sworndisk::{Hba, CONFIG};
use crate::layers::bio::{BlockSet, Buf, BufRef, BID_SIZE};
use crate::layers::log::{TxLog, TxLogStore};
use crate::os::{BTreeMap, Condvar, CvarMutex, Mutex};
use crate::prelude::*;
use crate::util::BitMap;

use core::mem::size_of;
use core::num::NonZeroUsize;
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use pod::Pod;
use serde::{Deserialize, Serialize};

/// The bucket name of block validity table.
const BUCKET_BLOCK_VALIDITY_TABLE: &str = "BVT";
/// The bucket name of block alloc/dealloc log.
const BUCKET_BLOCK_ALLOC_LOG: &str = "BAL";
/// The bucket name of segment table.
const BUCKET_SEGMENT_TABLE: &str = "SEG";

/// Block validity table. Global allocator for `SwornDisk`,
/// which manages validities of user data blocks.
pub(super) struct AllocTable {
    bitmap: Arc<Mutex<BitMap>>,
    /// Segment table for GC, only created when enable_gc=true
    segment_table: Option<Vec<Segment>>,
    next_avail: AtomicUsize,
    nblocks: NonZeroUsize,
    is_dirty: AtomicBool,
    cvar: Condvar,
    num_free: CvarMutex<usize>,
}

/// Per-TX block allocator in `SwornDisk`, recording validities
/// of user data blocks within each TX. All metadata will be stored in
/// `TxLog`s of bucket `BAL` during TX for durability and recovery purpose.
pub(super) struct BlockAlloc<D> {
    alloc_table: Arc<AllocTable>, // Point to the global allocator
    diff_table: Mutex<BTreeMap<Hba, AllocDiff>>, // Per-TX diffs of block validity
    store: Arc<TxLogStore<D>>,    // Store for diff log from L3
    diff_log: Mutex<Option<Arc<TxLog<D>>>>, // Opened diff log (currently not in-use)
}

/// Incremental diff of block validity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub(super) enum AllocDiff {
    Alloc = 3,
    Dealloc = 7,
    Invalid,
}
const DIFF_RECORD_SIZE: usize = size_of::<AllocDiff>() + size_of::<Hba>();

impl AllocTable {
    /// Create a new `AllocTable` given the total number of blocks.
    pub fn new(nblocks: NonZeroUsize) -> Self {
        let total_blocks = nblocks.get();
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, nblocks.get())));

        // Only create segment_table when GC is enabled
        let segment_table = if CONFIG.get().enable_gc {
            let segment_nums = total_blocks / SEGMENT_SIZE;
            let mut table = Vec::with_capacity(segment_nums);
            for id in 0..segment_nums {
                table.push(Segment::new(id, SEGMENT_SIZE, bitmap.clone()));
            }
            Some(table)
        } else {
            None
        };

        Self {
            bitmap,
            segment_table,
            next_avail: AtomicUsize::new(0),
            nblocks,
            is_dirty: AtomicBool::new(false),
            cvar: Condvar::new(),
            num_free: CvarMutex::new(nblocks.get()),
        }
    }

    /// Allocate a free slot for a new block, returns `None`
    /// if there are no free slots.
    pub fn alloc(&self) -> Option<Hba> {
        let mut bitmap = self.bitmap.lock();
        let next_avail = self.next_avail.load(Ordering::Acquire);

        let hba = if let Some(hba) = bitmap.first_one(next_avail) {
            hba
        } else {
            bitmap.first_one(0)?
        };
        bitmap.set(hba, false);

        // Only update segment_table when GC is enabled
        if let Some(ref segment_table) = self.segment_table {
            let segment_id = hba / SEGMENT_SIZE;
            segment_table[segment_id].mark_alloc();
        }

        self.next_avail.store(hba + 1, Ordering::Release);
        Some(hba as Hba)
    }

    /// Allocate multiple free slots for a bunch of new blocks, returns `None`
    /// if there are no free slots for all.
    pub fn alloc_batch(&self, count: NonZeroUsize) -> Result<Vec<Hba>> {
        let cnt = count.get();
        let mut num_free = self.num_free.lock().unwrap();
        if *num_free < cnt {
            return Err(Error::with_msg(OutOfDisk, "no free slots"));
        }
        while *num_free < cnt {
            // TODO: May not be woken, may require manual triggering of a compaction in L4
            debug!("num_free < cnt, require compaction");
            num_free = self.cvar.wait(num_free).unwrap();
        }
        debug_assert!(*num_free >= cnt);

        let Some(hbas) = self.do_alloc_batch(count) else {
            return_errno_with_msg!(OutOfDisk, "allocate blocks failed");
        };
        debug_assert_eq!(hbas.len(), cnt);

        // Only update segment_table when GC is enabled
        if let Some(ref segment_table) = self.segment_table {
            hbas.iter().for_each(|hba| {
                let segment_id = *hba / SEGMENT_SIZE;
                segment_table[segment_id].mark_alloc();
            });
        }

        *num_free -= cnt;
        let _ = self
            .is_dirty
            .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed);
        Ok(hbas)
    }

    fn do_alloc_batch(&self, count: NonZeroUsize) -> Option<Vec<Hba>> {
        let count = count.get();
        debug_assert!(count > 0);
        let mut bitmap = self.bitmap.lock();
        let mut next_avail = self.next_avail.load(Ordering::Acquire);

        if next_avail + count > self.nblocks.get() {
            next_avail = bitmap.first_one(0)?;
        }

        let hbas = if let Some(hbas) = bitmap.first_ones(next_avail, count) {
            hbas
        } else {
            next_avail = bitmap.first_one(0)?;
            bitmap.first_ones(next_avail, count)?
        };
        hbas.iter().for_each(|hba| bitmap.set(*hba, false));

        next_avail = hbas.last().unwrap() + 1;
        self.next_avail.store(next_avail, Ordering::Release);
        Some(hbas)
    }

    /// Recover the `AllocTable` from the latest `BVT` log and a bunch of `BAL` logs
    /// in the given store.
    pub fn recover<D: BlockSet + 'static>(
        nblocks: NonZeroUsize,
        store: &Arc<TxLogStore<D>>,
    ) -> Result<Self> {
        let total_blocks = nblocks.get();
        let segment_nums = total_blocks / SEGMENT_SIZE;
        let enable_gc = CONFIG.get().enable_gc;

        // Only recover segment_table when GC is enabled
        let recover_segment_table_from_log =
            |bitmap: Arc<Mutex<BitMap>>| -> Result<Option<Vec<Segment>>> {
                if !enable_gc {
                    return Ok(None);
                }
                let seg_log_res = store.open_log_in(BUCKET_SEGMENT_TABLE);
                let segment_table = match seg_log_res {
                    Ok(seg_log) => {
                        let mut buf = Buf::alloc(seg_log.nblocks())?;
                        seg_log.read(0 as BlockId, buf.as_mut())?;
                        recover_segment_table(segment_nums, buf.as_slice(), bitmap)?
                    }
                    Err(e) => {
                        if e.errno() != NotFound {
                            return Err(e);
                        }
                        (0..segment_nums)
                            .map(|id| Segment::new(id, SEGMENT_SIZE, bitmap.clone()))
                            .collect()
                    }
                };
                Ok(Some(segment_table))
            };

        let mut tx = store.new_tx();
        let res: Result<_> = tx.context(|| {
            // Recover the block validity table from `BVT` log first
            let bvt_log_res = store.open_log_in(BUCKET_BLOCK_VALIDITY_TABLE);
            let mut bitmap = match bvt_log_res {
                Ok(bvt_log) => {
                    let mut buf = Buf::alloc(bvt_log.nblocks())?;
                    bvt_log.read(0 as BlockId, buf.as_mut())?;
                    postcard::from_bytes(buf.as_slice()).map_err(|_| {
                        Error::with_msg(InvalidArgs, "deserialize block validity table failed")
                    })?
                }
                Err(e) => {
                    if e.errno() != NotFound {
                        return Err(e);
                    }
                    BitMap::repeat(true, nblocks.get())
                }
            };

            // Iterate each `BAL` log and apply each diff, from older to newer
            let bal_log_ids_res = store.list_logs_in(BUCKET_BLOCK_ALLOC_LOG);
            if let Err(e) = &bal_log_ids_res
                && e.errno() == NotFound
            {
                let next_avail = bitmap.first_one(0).unwrap_or(0);
                let num_free = bitmap.count_ones();
                let bitmap_ref = Arc::new(Mutex::new(bitmap));
                let segment_table = recover_segment_table_from_log(bitmap_ref.clone())?;
                return Ok(Self {
                    bitmap: bitmap_ref,
                    segment_table,
                    next_avail: AtomicUsize::new(next_avail),
                    nblocks,
                    is_dirty: AtomicBool::new(false),
                    cvar: Condvar::new(),
                    num_free: CvarMutex::new(num_free),
                });
            }
            let mut bal_log_ids = bal_log_ids_res?;
            bal_log_ids.sort();

            for bal_log_id in bal_log_ids {
                let bal_log_res = store.open_log(bal_log_id, false);
                if let Err(e) = &bal_log_res
                    && e.errno() == NotFound
                {
                    continue;
                }
                let bal_log = bal_log_res?;

                let log_nblocks = bal_log.nblocks();
                let mut buf = Buf::alloc(log_nblocks)?;
                bal_log.read(0 as BlockId, buf.as_mut())?;
                let buf_slice = buf.as_slice();
                let mut offset = 0;
                while offset <= log_nblocks * BLOCK_SIZE - DIFF_RECORD_SIZE {
                    let diff = AllocDiff::from(buf_slice[offset]);
                    offset += 1;
                    if diff == AllocDiff::Invalid {
                        continue;
                    }
                    let bid = BlockId::from_bytes(&buf_slice[offset..offset + BID_SIZE]);
                    offset += BID_SIZE;
                    match diff {
                        AllocDiff::Alloc => bitmap.set(bid, false),
                        AllocDiff::Dealloc => bitmap.set(bid, true),
                        _ => unreachable!(),
                    }
                }
            }
            let next_avail = bitmap.first_one(0).unwrap_or(0);
            let num_free = bitmap.count_ones();
            let bitmap_ref = Arc::new(Mutex::new(bitmap));
            let segment_table = recover_segment_table_from_log(bitmap_ref.clone())?;
            Ok(Self {
                bitmap: bitmap_ref,
                segment_table,
                next_avail: AtomicUsize::new(next_avail),
                nblocks,
                is_dirty: AtomicBool::new(false),
                cvar: Condvar::new(),
                num_free: CvarMutex::new(num_free),
            })
        });
        let recov_self = res.map_err(|_| {
            tx.abort();
            Error::with_msg(TxAborted, "recover block validity table TX aborted")
        })?;
        tx.commit()?;

        Ok(recov_self)
    }

    /// Persist the block validity table to `BVT` log. GC all existed `BAL` logs.
    pub fn do_compaction<D: BlockSet + 'static>(&self, store: &Arc<TxLogStore<D>>) -> Result<()> {
        if !self.is_dirty.load(Ordering::Relaxed) {
            return Ok(());
        }

        // Serialize the block validity table
        let bitmap = self.bitmap.lock();
        const BITMAP_MAX_SIZE: usize = 1792 * BLOCK_SIZE; // TBD
        let mut ser_buf = vec![0; BITMAP_MAX_SIZE];
        let ser_len = postcard::to_slice::<BitMap>(&bitmap, &mut ser_buf)
            .map_err(|_| Error::with_msg(InvalidArgs, "serialize block validity table failed"))?
            .len();
        ser_buf.resize(align_up(ser_len, BLOCK_SIZE), 0);
        drop(bitmap);

        // Only serialize segment_table when GC is enabled
        let ser_seg_buf = if let Some(ref segment_table) = self.segment_table {
            let segment_table_len = segment_table.len();
            let mut buf = vec![0; Segment::ser_size() * segment_table_len];
            let mut ser_len = 0;
            segment_table
                .iter()
                .enumerate()
                .try_for_each(|(idx, segment)| {
                    let offset = idx * Segment::ser_size();
                    let segment_buf = &mut buf[offset..offset + Segment::ser_size()];
                    ser_len += segment.to_slice(segment_buf)?;
                    Ok::<_, Error>(())
                })?;
            buf.resize(align_up(ser_len, BLOCK_SIZE), 0);
            Some(buf)
        } else {
            None
        };

        // Persist the serialized block validity table to `BVT` log
        // and GC any old `BVT` logs and `BAL` logs
        let mut tx = store.new_tx();
        let res: Result<_> = tx.context(|| {
            if let Ok(bvt_log_ids) = store.list_logs_in(BUCKET_BLOCK_VALIDITY_TABLE) {
                for bvt_log_id in bvt_log_ids {
                    store.delete_log(bvt_log_id)?;
                }
            }

            // Only persist/delete segment_table logs when GC is enabled
            if ser_seg_buf.is_some() {
                if let Ok(seg_log_ids) = store.list_logs_in(BUCKET_SEGMENT_TABLE) {
                    for seg_log_id in seg_log_ids {
                        store.delete_log(seg_log_id)?;
                    }
                }
            }

            let bvt_log = store.create_log(BUCKET_BLOCK_VALIDITY_TABLE)?;
            bvt_log.append(BufRef::try_from(&ser_buf[..]).unwrap())?;

            // Only create segment_table log when GC is enabled
            if let Some(ref buf) = ser_seg_buf {
                let seg_log = store.create_log(BUCKET_SEGMENT_TABLE)?;
                seg_log.append(BufRef::try_from(&buf[..]).unwrap())?;
            }

            if let Ok(bal_log_ids) = store.list_logs_in(BUCKET_BLOCK_ALLOC_LOG) {
                for bal_log_id in bal_log_ids {
                    store.delete_log(bal_log_id)?;
                }
            }
            Ok(())
        });
        if res.is_err() {
            tx.abort();
            return_errno_with_msg!(TxAborted, "persist block validity table TX aborted");
        }
        tx.commit()?;

        self.is_dirty.store(false, Ordering::Relaxed);
        Ok(())
    }

    // Migrate a batch of blocks to another segment.
    // the blocks has been marked as allocated before, so the total num_free will not be decreased
    // Note: This function is only called when GC is enabled
    pub fn migrate_batch(&self, hbas: &[Hba]) {
        let mut bitmap = self.bitmap.lock();
        if let Some(ref segment_table) = self.segment_table {
            hbas.iter().for_each(|hba| {
                let segment_id = *hba / SEGMENT_SIZE;
                segment_table[segment_id].mark_alloc();
                bitmap.set(*hba, false);
            });
        } else {
            hbas.iter().for_each(|hba| {
                bitmap.set(*hba, false);
            });
        }
    }

    /// Mark a specific slot deallocated.
    pub fn set_deallocated(&self, nth: usize) {
        let mut num_free = self.num_free.lock().unwrap();
        self.bitmap.lock().set(nth, true);

        // Only update segment_table when GC is enabled
        if let Some(ref segment_table) = self.segment_table {
            let segment_id = nth / SEGMENT_SIZE;
            segment_table[segment_id].mark_deallocated();
        }

        *num_free += 1;
        const AVG_ALLOC_COUNT: usize = 1024;
        if *num_free >= AVG_ALLOC_COUNT {
            self.cvar.notify_one();
        }
    }

    // GC will deallocate out-of-date blocks before compaction
    // discard these blocks and increase num_free
    // Note: This function is only called when GC is enabled
    pub fn clear_segment(&self, segment_id: SegmentId, discard_count: usize) {
        *self.num_free.lock().unwrap() += discard_count;
        let mut bitmap = self.bitmap.lock();
        let begin_hba = segment_id * SEGMENT_SIZE;
        let end_hba = begin_hba + SEGMENT_SIZE;
        for hba in begin_hba..end_hba {
            bitmap.set(hba, true);
        }
        if let Some(ref segment_table) = self.segment_table {
            segment_table[segment_id].clear_segment();
        }
    }

    /// Get reference to segment_table for GC, returns None if GC is disabled
    pub fn get_segment_table_ref(&self) -> Option<&[Segment]> {
        self.segment_table.as_deref()
    }
}

impl<D: BlockSet + 'static> BlockAlloc<D> {
    /// Create a new `BlockAlloc` with the given global allocator and store.
    pub fn new(alloc_table: Arc<AllocTable>, store: Arc<TxLogStore<D>>) -> Self {
        Self {
            alloc_table,
            diff_table: Mutex::new(BTreeMap::new()),
            store,
            diff_log: Mutex::new(None),
        }
    }

    /// Record a diff of `Alloc`.
    pub fn alloc_block(&self, block_id: Hba) -> Result<()> {
        let mut diff_table = self.diff_table.lock();
        let replaced = diff_table.insert(block_id, AllocDiff::Alloc);
        debug_assert!(
            replaced != Some(AllocDiff::Alloc),
            "can't allocate a block twice"
        );
        Ok(())
    }

    /// Record a diff of `Dealloc`.
    pub fn dealloc_block(&self, block_id: Hba) -> Result<()> {
        let mut diff_table = self.diff_table.lock();
        let replaced = diff_table.insert(block_id, AllocDiff::Dealloc);
        debug_assert!(
            replaced != Some(AllocDiff::Dealloc),
            "can't deallocate a block twice"
        );
        Ok(())
    }

    /// Prepare the block validity diff log.
    ///
    /// # Panics
    ///
    /// This method must be called within a TX. Otherwise, this method panics.
    pub fn prepare_diff_log(&self) -> Result<()> {
        // Do nothing for now
        Ok(())
    }

    /// Persist the metadata in diff table to the block validity diff log.
    ///
    /// # Panics
    ///
    /// This method must be called within a TX. Otherwise, this method panics.
    pub fn update_diff_log(&self) -> Result<()> {
        let diff_table = self.diff_table.lock();
        if diff_table.is_empty() {
            return Ok(());
        }

        let diff_log = self.store.create_log(BUCKET_BLOCK_ALLOC_LOG)?;

        const MAX_BUF_SIZE: usize = 1024 * BLOCK_SIZE;
        let mut diff_buf = Vec::with_capacity(MAX_BUF_SIZE);
        for (block_id, block_diff) in diff_table.iter() {
            diff_buf.push(*block_diff as u8);
            diff_buf.extend_from_slice(block_id.as_bytes());

            if diff_buf.len() + DIFF_RECORD_SIZE > MAX_BUF_SIZE {
                diff_buf.resize(align_up(diff_buf.len(), BLOCK_SIZE), 0);
                diff_log.append(BufRef::try_from(&diff_buf[..]).unwrap())?;
                diff_buf.clear();
            }
        }

        if diff_buf.is_empty() {
            return Ok(());
        }
        diff_buf.resize(align_up(diff_buf.len(), BLOCK_SIZE), 0);
        diff_log.append(BufRef::try_from(&diff_buf[..]).unwrap())
    }

    /// Update the metadata in diff table to the in-memory block validity table.
    pub fn update_alloc_table(&self) {
        let diff_table = self.diff_table.lock();
        let alloc_table = &self.alloc_table;
        let mut num_free = alloc_table.num_free.lock().unwrap();
        let mut bitmap = alloc_table.bitmap.lock();
        let mut num_dealloc = 0_usize;
        for (block_id, block_diff) in diff_table.iter() {
            match block_diff {
                AllocDiff::Alloc => {
                    debug_assert!(!bitmap[*block_id]);
                }
                AllocDiff::Dealloc => {
                    debug_assert!(!bitmap[*block_id]);
                    bitmap.set(*block_id, true);
                    num_dealloc += 1;
                }
                AllocDiff::Invalid => unreachable!(),
            };
        }

        *num_free += num_dealloc;
        const AVG_ALLOC_COUNT: usize = 1024;
        if *num_free >= AVG_ALLOC_COUNT {
            alloc_table.cvar.notify_one();
        }
    }
}

impl From<u8> for AllocDiff {
    fn from(value: u8) -> Self {
        match value {
            3 => AllocDiff::Alloc,
            7 => AllocDiff::Dealloc,
            _ => AllocDiff::Invalid,
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::layers::disk::{
        block_alloc::AllocTable, config::Config, segment::SEGMENT_SIZE, sworndisk::CONFIG,
    };
    use core::num::NonZeroUsize;

    fn setup_gc_enabled() {
        CONFIG.set(Config {
            enable_gc: true,
            ..Default::default()
        });
    }

    #[test]
    fn test_alloc_table() {
        setup_gc_enabled();
        let alloc_table = AllocTable::new(NonZeroUsize::new(1024).unwrap());
        let segment_table = alloc_table.segment_table.as_ref().unwrap();
        assert_eq!(alloc_table.alloc(), Some(0));
        assert_eq!(alloc_table.alloc(), Some(1));
        assert_eq!(segment_table[0].num_valid_blocks(), 1024);
        assert_eq!(segment_table[0].free_space(), 1022);

        alloc_table.set_deallocated(0);
        assert_eq!(segment_table[0].num_valid_blocks(), 1023);
        assert_eq!(segment_table[0].free_space(), 1023);
        alloc_table.set_deallocated(1);
        assert_eq!(segment_table[0].num_valid_blocks(), 1022);
        assert_eq!(segment_table[0].free_space(), 1024);
    }

    #[test]
    fn test_alloc_table_batch() {
        setup_gc_enabled();
        let alloc_table = AllocTable::new(NonZeroUsize::new(1024).unwrap());
        let segment_table = alloc_table.segment_table.as_ref().unwrap();
        let hbas = alloc_table
            .alloc_batch(NonZeroUsize::new(1024).unwrap())
            .unwrap();
        assert_eq!(hbas.len(), 1024);
        assert!(segment_table[0].num_valid_blocks() == 1024);
        assert_eq!(segment_table[0].free_space(), 0);

        let alloc_table = AllocTable::new(NonZeroUsize::new(4 * SEGMENT_SIZE).unwrap());
        let segment_table = alloc_table.segment_table.as_ref().unwrap();
        let hbas = alloc_table
            .alloc_batch(NonZeroUsize::new(SEGMENT_SIZE + 2).unwrap())
            .unwrap();
        assert_eq!(hbas.len(), 1026);
        assert_eq!(segment_table[0].num_valid_blocks(), 1024);
        assert_eq!(segment_table[1].num_valid_blocks(), 1024);
        assert_eq!(segment_table[0].free_space(), 0);
        assert_eq!(segment_table[1].free_space(), 1022);

        alloc_table.set_deallocated(1024);
        assert_eq!(segment_table[1].num_valid_blocks(), 1023);
        assert_eq!(segment_table[1].free_space(), 1023);

        setup_gc_enabled();
        let alloc_table = AllocTable::new(NonZeroUsize::new(200 * SEGMENT_SIZE).unwrap());
        let segment_table = alloc_table.segment_table.as_ref().unwrap();
        let hbas = alloc_table
            .alloc_batch(NonZeroUsize::new(100 * SEGMENT_SIZE + 2).unwrap())
            .unwrap();
        assert_eq!(hbas.len(), 100 * SEGMENT_SIZE + 2);
        for segment_id in 0..100 {
            assert_eq!(segment_table[segment_id].num_valid_blocks(), SEGMENT_SIZE);
            assert_eq!(segment_table[segment_id].free_space(), 0);
        }
        assert_eq!(segment_table[100].num_valid_blocks(), 1024);
        assert_eq!(segment_table[100].free_space(), 1022);
    }
}

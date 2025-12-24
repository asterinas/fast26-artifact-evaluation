use super::{
    block_alloc::{AllocTable, BlockAlloc},
    dealloc_block::DeallocTable,
    segment::{Segment, SegmentId},
    sworndisk::{Hba, Lba, RecordKey, RecordValue},
};
use crate::{
    layers::{
        disk::segment::SEGMENT_SIZE,
        lsm::{RecordKey as RecordK, RecordValue as RecordV, TxLsmTree},
    },
    tx::TxProvider,
    BlockSet, Error,
};
use crate::{
    layers::{
        disk::{bio::BlockBuf, block_alloc},
        log::TxLogStore,
    },
    prelude::Result,
    Buf, BLOCK_SIZE,
};
use crate::{
    os::{sleep, Arc, BTreeMap, Condvar, CvarMutex, Mutex, Vec},
    prelude,
};
use core::{
    ops::{Add, Sub},
    sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU64, AtomicUsize, Ordering},
    time::Duration,
    usize,
};
use hashbrown::{HashMap, HashSet};
use log::debug;
use pod::Pod;
use std::time::Instant;
// Default gc interval time is 30 seconds
const ACTIVE_GC_INTERVAL_TIME: core::time::Duration = core::time::Duration::from_secs(5);
const INACTIVE_GC_INTERVAL_TIME: core::time::Duration = core::time::Duration::from_millis(100);
const GC_WATERMARK: usize = 16;
const ACTIVE_GC_THRESHOLD: f64 = 0.6;
const INACTIVE_GC_THRESHOLD: f64 = 0.1;

#[repr(C)]
#[derive(Clone, Copy, Pod, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct ReverseKey {
    pub hba: Hba,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Debug)]
pub struct ReverseValue {
    pub lba: Lba,
}

impl Add<usize> for ReverseKey {
    type Output = Self;

    fn add(self, rhs: usize) -> Self::Output {
        Self {
            hba: self.hba + rhs,
        }
    }
}

impl Sub<ReverseKey> for ReverseKey {
    type Output = usize;

    fn sub(self, rhs: ReverseKey) -> Self::Output {
        self.hba - rhs.hba
    }
}

impl RecordK<ReverseKey> for ReverseKey {}
impl RecordV for ReverseValue {}

// SharedState is used to synchronize background GC and foreground I/O requests and lsm compaction
// 1. Background GC will stop the world, I/O requests and lsm compaction will be blocked
// 2. Background GC should wait until lsm compaction are done
// TODO: 3. Should background GC wait for all I/O requests to finished?

pub type SharedStateRef = Arc<SharedState>;
pub struct SharedState {
    gc_in_progress: CvarMutex<bool>,
    compaction_in_progress: CvarMutex<bool>,
    gc_condvar: Condvar,
    compaction_condvar: Condvar,
}

impl SharedState {
    pub fn new() -> Self {
        Self {
            gc_in_progress: CvarMutex::new(false),
            compaction_in_progress: CvarMutex::new(false),
            gc_condvar: Condvar::new(),
            compaction_condvar: Condvar::new(),
        }
    }

    // Compaction worker and I/O requests will call this function to wait for background GC
    pub fn wait_for_background_gc(&self) {
        let mut gc_in_progress = self.gc_in_progress.lock().unwrap();
        while *gc_in_progress {
            #[cfg(not(feature = "linux"))]
            debug!("Waiting for background GC to finish");
            gc_in_progress = self.gc_condvar.wait(gc_in_progress).unwrap();
        }
    }

    // Background GC will call this function to wait for compaction finished
    pub fn wait_for_compaction(&self) {
        let mut compaction_in_progress = self.compaction_in_progress.lock().unwrap();
        while *compaction_in_progress {
            #[cfg(not(feature = "linux"))]
            debug!("Waiting for compaction to finish");
            compaction_in_progress = self
                .compaction_condvar
                .wait(compaction_in_progress)
                .unwrap();
        }
    }

    pub fn start_gc(&self) {
        let mut gc_in_progress = self.gc_in_progress.lock().unwrap();
        *gc_in_progress = true;
    }

    pub fn start_compaction(&self) {
        #[cfg(not(feature = "linux"))]
        debug!("Background compaction started");
        let mut compaction_in_progress = self.compaction_in_progress.lock().unwrap();
        *compaction_in_progress = true;
    }

    pub fn notify_gc_finished(&self) {
        let mut gc_in_progress = self.gc_in_progress.lock().unwrap();
        *gc_in_progress = false;
        self.gc_condvar.notify_all();
    }

    pub fn notify_compaction_finished(&self) {
        #[cfg(not(feature = "linux"))]
        debug!("Background compaction finished");
        let mut compaction_in_progress = self.compaction_in_progress.lock().unwrap();
        *compaction_in_progress = false;
        self.compaction_condvar.notify_all();
    }
}

pub struct Victim {
    segment_id: SegmentId,
    blocks: Vec<Hba>,
}

pub trait VictimPolicy: Send + Sync {
    fn pick_victim(&self, segment_table: &[Segment], threshold: f64) -> Option<Victim>;
}

pub type VictimPolicyRef = Arc<dyn VictimPolicy>;

pub struct GreedyVictimPolicy {}

impl VictimPolicy for GreedyVictimPolicy {
    // pick the segment with the maximum number of invalid blocks
    fn pick_victim(&self, segment_table: &[Segment], threshold: f64) -> Option<Victim> {
        let mut max_num_invalid_blocks = 0;
        let mut victim = None;
        segment_table.iter().enumerate().for_each(|(i, segment)| {
            let invalid_block_fraction =
                segment.num_invalid_blocks() as f64 / segment.nblocks() as f64;
            if invalid_block_fraction > threshold
                && segment.num_invalid_blocks() > max_num_invalid_blocks
            {
                max_num_invalid_blocks = segment.num_invalid_blocks();
                victim = Some(Victim {
                    segment_id: i,
                    blocks: vec![],
                });
            }
        });
        victim.map(|mut victim| {
            let victim_segment = &segment_table[victim.segment_id];
            victim.blocks = victim_segment.find_all_allocated_blocks();
            victim
        })
    }
}

pub struct LoopScanVictimPolicy {
    cursor: AtomicUsize,
}

impl LoopScanVictimPolicy {
    pub fn new() -> Self {
        Self {
            cursor: AtomicUsize::new(0),
        }
    }
}

impl VictimPolicy for LoopScanVictimPolicy {
    fn pick_victim(&self, segment_table: &[Segment], threshold: f64) -> Option<Victim> {
        let last_cursor = self.cursor.load(Ordering::Relaxed);
        let mut cursor = last_cursor;
        loop {
            cursor = (cursor + 1) % segment_table.len();
            if cursor == last_cursor {
                return None;
            }
            let segment = &segment_table[cursor];
            let invalid_block_fraction =
                segment.num_invalid_blocks() as f64 / segment.nblocks() as f64;
            if invalid_block_fraction > threshold {
                self.cursor.store(cursor, Ordering::Release);
                return Some(Victim {
                    segment_id: cursor,
                    blocks: segment.find_all_allocated_blocks(),
                });
            }
        }
    }
}

pub(super) struct GcWorker<D> {
    victim_policy: VictimPolicyRef,
    logical_block_table: TxLsmTree<RecordKey, RecordValue, D>,
    reverse_index_table: TxLsmTree<ReverseKey, ReverseValue, D>,
    dealloc_table: Arc<DeallocTable>,
    block_validity_table: Arc<AllocTable>,
    tx_log_store: Arc<TxLogStore<D>>,
    tx_provider: Arc<TxProvider>,
    user_data_disk: Arc<D>,
    shared_state: SharedStateRef,
    is_active: Arc<AtomicBool>,
}

impl<D: BlockSet + 'static> GcWorker<D> {
    pub fn new(
        victim_policy: VictimPolicyRef,
        logical_block_table: TxLsmTree<RecordKey, RecordValue, D>,
        reverse_index_table: TxLsmTree<ReverseKey, ReverseValue, D>,
        dealloc_table: Arc<DeallocTable>,
        tx_log_store: Arc<TxLogStore<D>>,
        block_validity_table: Arc<AllocTable>,
        user_data_disk: Arc<D>,
        shared_state: SharedStateRef,
        last_active_time: Arc<AtomicBool>,
    ) -> Self {
        let tx_provider = TxProvider::new();
        Self {
            victim_policy,
            logical_block_table,
            reverse_index_table,
            dealloc_table,
            block_validity_table,
            tx_log_store,
            user_data_disk,
            shared_state,
            tx_provider,
            is_active: last_active_time,
        }
    }

    pub fn run(&self) -> Result<()> {
        loop {
            #[cfg(not(feature = "linux"))]
            debug!("Background GC started");
            self.shared_state.start_gc();
            self.background_gc()?;
            // Notify foreground GC and foreground I/O Requests
            self.shared_state.notify_gc_finished();
            if self.is_active() {
                self.is_active.store(false, Ordering::Release);
                sleep(ACTIVE_GC_INTERVAL_TIME);
            } else {
                self.is_active.store(false, Ordering::Release);
                sleep(INACTIVE_GC_INTERVAL_TIME);
            }
        }
    }

    // pub fn foreground_gc(&self) -> Result<()> {
    //     self.shared_state.wait_for_background_gc();
    //     let victim = self.victim_policy.pick_victim(
    //         self.block_validity_table.get_segment_table_ref(),
    //         DEFAULT_GC_THRESHOLD,
    //     );
    //     if !self.trigger_gc(victim.as_ref()) {
    //         return Ok(());
    //     }
    //     // Safety: if victim is none, the function will return early
    //     let remapped_hbas = self.clean_and_migrate_data(victim.unwrap())?;
    //     self.remap_index_batch(remapped_hbas)?;
    //     Ok(())
    // }

    pub fn is_active(&self) -> bool {
        self.is_active.load(Ordering::Acquire)
    }
    pub fn background_gc(&self) -> Result<()> {
        // FIXME: use a cross-platform time function
        #[cfg(feature = "std")]
        let start = std::time::Instant::now();

        let mut segment_ids = Vec::with_capacity(GC_WATERMARK);

        let threshold = if self.is_active() {
            ACTIVE_GC_THRESHOLD
        } else {
            INACTIVE_GC_THRESHOLD
        };

        for _ in 0..GC_WATERMARK {
            let victim = self
                .victim_policy
                .pick_victim(self.block_validity_table.get_segment_table_ref(), threshold);

            // Generally, the VictimPolicy will pick a victim segment that most needs GC
            // if it returned None, it means there is no segment needs GC, we can return
            let Some(victim) = victim else {
                break;
            };
            segment_ids.push(victim.segment_id);

            let mut tx = self.tx_provider.new_tx();
            let ret: Result<_> = tx.context(|| {
                let remapped_hbas = self.clean_and_migrate_data(victim)?;
                self.remap_index_batch(remapped_hbas)?;
                Ok(())
            });
            if ret.is_err() {
                tx.abort();
                return Err(ret.err().unwrap());
            }
            tx.commit()?;
        }

        #[cfg(feature = "std")]
        {
            let duration = start.elapsed();
            debug!(
                "Background GC succeed, freed {} segments, segment_ids: {:?},took {:?}",
                segment_ids.len(),
                segment_ids,
                duration
            );
        }

        Ok(())
    }

    // TODO: move this function to GcWorker
    // After data migration in GC task, we need:
    // 1. update the hba of the records in lsm tree
    // 2. update the reverse index table, record the old hba of the migrated blocks and insert the new hba -> lba mapping
    // 3. insert the lba -> old hba mapping into the dealloc table to prevent double deallocation in compaction
    pub fn remap_index_batch(&self, remapped_hbas: Vec<(Hba, Hba)>) -> Result<()> {
        remapped_hbas
            .into_iter()
            .try_for_each(|(old_hba, new_hba)| {
                // Get the lba of the old hba
                // Safety: hba should exist in index table, otherwise it means system is inconsistent
                let key = ReverseKey { hba: old_hba };
                let lba = self
                    .reverse_index_table
                    .get(&key)
                    .map(|value| value.lba)
                    .expect("hba should exist in index table");
                let record_key = RecordKey { lba };

                // get mac and key of the old hba record
                // Safety: hba should exist in lsm tree, otherwise it means system is inconsistent
                let mut record_value = self
                    .logical_block_table
                    .get(&record_key)
                    .expect("record key should exist in lsm tree");

                // Update the hba of the record but keep the key and mac unchanged
                // This will trigger deallocation of the old hba in MemTable
                record_value.hba = new_hba;

                // write the record back to lsm tree
                self.logical_block_table.put(record_key, record_value)?;

                let reverse_index_key = ReverseKey { hba: new_hba };

                // update the reverse index table
                let reverse_index_value = ReverseValue { lba };
                self.reverse_index_table
                    .put(reverse_index_key, reverse_index_value)?;
                self.dealloc_table.mark_deallocated(old_hba);
                Ok::<_, Error>(())
            })?;
        Ok::<_, Error>(())
    }

    // Find valid blocks to migrate and invalid blocks to discard and free blocks to store
    pub fn find_target_hbas(
        &self,
        victim: Victim,
    ) -> Result<(Vec<Hba>, Vec<(Lba, Hba)>, Vec<Hba>)> {
        let victim_segment = &self.block_validity_table.get_segment_table_ref()[victim.segment_id];

        let (valid_hbas, discard_hbas) = victim.blocks.into_iter().try_fold(
            (Vec::new(), Vec::new()),
            |(mut valid, mut discard), hba| {
                // if victim hba is different from the hba that stored in logical block table,
                // it means the block is already invalid but not deallocated by compaction,
                // it should be discarded and be marked to avoid double free
                //let lba = self.reverse_index_table.get_lba(&hba);
                let reverse_index_key = ReverseKey { hba };
                let lba = self.reverse_index_table.get(&reverse_index_key)?.lba;
                let old_hba = self.logical_block_table.get(&RecordKey { lba })?.hba;
                if hba == old_hba {
                    valid.push(hba);
                } else {
                    discard.push((lba, hba));
                }
                Ok::<_, Error>((valid, discard))
            },
        )?;

        let mut target_hbas = Vec::new();
        let mut found_enough_blocks = false;
        for segment in self.block_validity_table.get_segment_table_ref() {
            if segment.free_space() == 0 || segment.segment_id() == victim_segment.segment_id() {
                continue;
            }
            let free_hbas = segment.find_all_free_blocks();
            for hba in free_hbas {
                if target_hbas.len() >= valid_hbas.len() {
                    found_enough_blocks = true;
                    break;
                }
                target_hbas.push(hba);
            }
            if found_enough_blocks {
                break;
            }
        }
        debug_assert_eq!(valid_hbas.len(), target_hbas.len());
        Ok((valid_hbas, discard_hbas, target_hbas))
    }

    pub fn clean_and_migrate_data(&self, victim: Victim) -> Result<Vec<(Hba, Hba)>> {
        let victim_segment = &self.block_validity_table.get_segment_table_ref()[victim.segment_id];

        //        let start = Instant::now();
        let (valid_hbas, discard_hbas, free_hbas) = self.find_target_hbas(victim)?;
        let mut victim_data = Buf::alloc(victim_segment.nblocks())?;
        let offset = victim_segment.segment_id() * SEGMENT_SIZE;
        self.user_data_disk.read(offset, victim_data.as_mut())?;
        // let duration = start.elapsed();
        // debug!("Find target hbas took {:?}", duration);

        // let start = Instant::now();
        let target_hba_batches = free_hbas.group_by(|hba1, hba2| hba2.saturating_sub(*hba1) == 1);
        let mut victim_hba_iter = valid_hbas.iter();
        for target_hba_batch in target_hba_batches {
            let batch_len = target_hba_batch.len();
            let mut write_buf = Buf::alloc(batch_len)?;

            // read enough blocks to fill the batch
            for i in 0..batch_len {
                let Some(victim_hba) = victim_hba_iter.next() else {
                    break;
                };
                let start = (victim_hba % SEGMENT_SIZE) * BLOCK_SIZE;
                let end = start + BLOCK_SIZE;

                let des_start = i * BLOCK_SIZE;
                let des_end = (i + 1) * BLOCK_SIZE;
                write_buf.as_mut_slice()[des_start..des_end]
                    .copy_from_slice(&victim_data.as_slice()[start..end]);
            }

            self.user_data_disk
                .write(*target_hba_batch.first().unwrap(), write_buf.as_ref())?;
        }
        // let duration = start.elapsed();
        // debug!("Write data to disk took {:?}", duration);

        self.block_validity_table.migrate_batch(&valid_hbas);
        self.block_validity_table
            .clear_segment(victim_segment.segment_id(), discard_hbas.len());

        Ok(valid_hbas.into_iter().zip(free_hbas).collect())
    }

    // TODO: Support more rules
    fn trigger_gc(&self, victim: Option<&Victim>) -> bool {
        if victim.is_none() {
            return false;
        }
        #[cfg(not(feature = "linux"))]
        debug!(
            "Triggered background GC, victim segment: {}",
            victim.unwrap().segment_id
        );
        true
    }

    // fn clean_segment(&self, segment: &Segment) -> Result<()> {
    //     segment.clear_segment();
    //     self.block_validity_table.set_deallocated(nth);
    // }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::os::Rng;
    use crate::util::Rng as UtilRng;
    use crate::BlockId;
    use crate::{
        layers::{
            bio::MemDisk,
            disk::{
                block_alloc::{AllocTable, BlockAlloc},
                gc::{GreedyVictimPolicy, VictimPolicy},
                segment::{Segment, SEGMENT_SIZE},
            },
            log::TxLogStore,
            lsm::{AsKV, SyncIdStore, TxEventListener, TxEventListenerFactory, TxLsmTree, TxType},
        },
        tx::Tx,
        util::BitMap,
        AeadKey, RandomInit, SwornDisk,
    };
    use core::num::NonZeroUsize;
    use spin::Mutex;
    use std::sync::{Arc, Once};

    static INIT_LOG: Once = Once::new();

    fn init_logger() {
        INIT_LOG.call_once(|| {
            env_logger::builder()
                .is_test(true)
                .filter_level(log::LevelFilter::Debug)
                .try_init()
                .unwrap();
        });
    }

    fn gen_rnd_pos(total_nblocks: usize, buf_nblocks: usize) -> BlockId {
        let mut rnd_pos_bytes = [0u8; 8];
        Rng::new(&[]).fill_bytes(&mut rnd_pos_bytes).unwrap();
        BlockId::from_le_bytes(rnd_pos_bytes) % (total_nblocks - buf_nblocks)
    }

    // I/O request will wait for background GC to finish
    #[test]
    fn io_and_gc_test() {
        //    init_logger();
        let finished = Arc::new(AtomicBool::new(false));
        let finished_clone = finished.clone();
        let shared_state = Arc::new(SharedState::new());
        let state_clone = shared_state.clone();
        assert!(!finished.load(Ordering::Acquire));

        std::thread::spawn(move || {
            shared_state.start_gc();
            std::thread::sleep(Duration::from_millis(100));
            finished_clone.store(true, Ordering::Release);
            shared_state.notify_gc_finished();
        });
        // Wait for background GC to start
        std::thread::sleep(Duration::from_millis(100));
        state_clone.wait_for_background_gc();
        assert!(finished.load(Ordering::Acquire));
    }

    #[test]
    fn gc_waits_for_compaction_test() {
        // init_logger();
        let finished = Arc::new(AtomicBool::new(false));
        let finished_clone = finished.clone();
        let shared_state = Arc::new(SharedState::new());
        let state_clone = shared_state.clone();
        let _compaction_thread = std::thread::spawn(move || {
            shared_state.wait_for_background_gc();
            shared_state.start_compaction();
            std::thread::sleep(Duration::from_millis(20));
            finished.store(true, Ordering::Release);
            shared_state.notify_compaction_finished();
        });

        let gc_thread = std::thread::spawn(move || {
            assert!(!finished_clone.load(Ordering::Acquire));
            std::thread::sleep(Duration::from_millis(10));
            state_clone.wait_for_compaction();
            state_clone.start_gc();
            std::thread::sleep(Duration::from_millis(10));
            assert!(finished_clone.load(Ordering::Acquire));
            state_clone.notify_gc_finished();
        });

        gc_thread.join().unwrap();
    }
    #[test]
    fn compaction_waits_for_gc_test() {
        // init_logger();
        let finished = Arc::new(AtomicBool::new(false));
        let finished_clone = finished.clone();
        let shared_state = Arc::new(SharedState::new());
        let state_clone = shared_state.clone();
        let compaction_thread = std::thread::spawn(move || {
            assert!(!finished.load(Ordering::Acquire));
            std::thread::sleep(Duration::from_millis(10));
            shared_state.wait_for_background_gc();
            shared_state.start_compaction();
            finished.store(true, Ordering::Release);
            shared_state.notify_compaction_finished();
        });

        let _gc_thread = std::thread::spawn(move || {
            state_clone.wait_for_compaction();
            state_clone.start_gc();
            std::thread::sleep(Duration::from_millis(20));
            finished_clone.store(true, Ordering::Release);
            state_clone.notify_gc_finished();
        });

        compaction_thread.join().unwrap();
    }

    // gc waits for compaction, io waits for gc
    #[test]
    fn compaction_gc_io_test() {
        //  init_logger();
        let finished = Arc::new(AtomicUsize::new(0));
        let shared_state = Arc::new(SharedState::new());

        std::thread::spawn({
            let finished = Arc::clone(&finished);
            let shared_state = Arc::clone(&shared_state);
            move || {
                assert!(finished.load(Ordering::Acquire) == 0);
                std::thread::sleep(Duration::from_millis(10));
                shared_state.wait_for_background_gc();
                shared_state.start_compaction();
                finished.store(1, Ordering::Release);
                shared_state.notify_compaction_finished();
            }
        });

        std::thread::spawn({
            let finished = Arc::clone(&finished);
            let shared_state = Arc::clone(&shared_state);
            move || {
                std::thread::sleep(Duration::from_millis(20));
                shared_state.wait_for_compaction();
                assert_eq!(finished.load(Ordering::Acquire), 1);
                shared_state.start_gc();
                std::thread::sleep(Duration::from_millis(20));
                finished.store(2, Ordering::Release);
                shared_state.notify_gc_finished();
            }
        });

        // background hasn't started yet return immediately
        shared_state.wait_for_background_gc();
        assert_eq!(finished.load(Ordering::Acquire), 0);
        std::thread::sleep(Duration::from_millis(30));

        shared_state.wait_for_background_gc();
        // background gc is running, wait for it to finish. result is modified by background gc thread
        assert_eq!(finished.load(Ordering::Acquire), 2);
    }

    #[test]
    fn greedy_victim_policy_test() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 3 * 1024)));
        let segment_table = vec![
            Segment::new(0, 1024, bitmap.clone()),
            Segment::new(1, 1024, bitmap.clone()),
            Segment::new(2, 1024, bitmap.clone()),
        ];
        let policy = GreedyVictimPolicy {};
        let victim = policy.pick_victim(&segment_table, 0.);
        assert!(victim.is_none());
        segment_table[1].mark_alloc();
        // After dealloc, there will be an invalid block in the segment, segment 1 will be the victim
        segment_table[1].mark_deallocated();
        let victim = policy.pick_victim(&segment_table, 0.);
        assert_eq!(victim.unwrap().segment_id, 1);
    }

    #[test]
    fn threshold_test() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 3 * 1024)));
        let segment_table = vec![
            Segment::new(0, 1024, bitmap.clone()),
            Segment::new(1, 1024, bitmap.clone()),
            Segment::new(2, 1024, bitmap.clone()),
        ];
        let policy = GreedyVictimPolicy {};
        let threshold = 0.2;
        let victim = policy.pick_victim(&segment_table, threshold);
        assert!(victim.is_none());

        // deallocate enough blocks to pick the segment as victim
        for _ in 0..((2 * SEGMENT_SIZE) as f64 * threshold) as usize {
            segment_table[1].mark_alloc();
            segment_table[1].mark_deallocated();
        }
        let victim = policy.pick_victim(&segment_table, threshold);
        assert_eq!(victim.unwrap().segment_id, 1);
    }

    #[test]
    fn simple_data_migration() {
        init_logger();
        let nblocks = 256 * SEGMENT_SIZE;
        let mem_disk = MemDisk::create(nblocks).unwrap();
        let greedy_victim_policy = GreedyVictimPolicy {};
        let root_key = AeadKey::random();

        let disk = SwornDisk::create(mem_disk, root_key, None, true, None).unwrap();
        let gc_worker = disk
            .create_gc_worker(Arc::new(greedy_victim_policy))
            .unwrap();
        //   background gc won't be triggered
        gc_worker.background_gc().unwrap();

        let content: Vec<u8> = vec![1; BLOCK_SIZE];
        let mut buf = Buf::alloc(1).unwrap();
        buf.as_mut_slice().copy_from_slice(&content);

        // write enough blocks to trigger gc,[0-298] blocks are invalid, only block 299 will be migrated
        for _ in 0..300 {
            disk.write(0, buf.as_ref()).unwrap();
            disk.sync().unwrap();
        }

        gc_worker.background_gc().unwrap();

        // after gc, the block at offset 0 should be migrated to another segment
        let mut read_buf = Buf::alloc(1).unwrap();
        disk.read(0, read_buf.as_mut()).unwrap();
        assert_eq!(read_buf.as_slice(), content);
    }

    #[test]
    fn batch_data_migration() {
        init_logger();
        let nblocks = 256 * SEGMENT_SIZE;
        let mem_disk = MemDisk::create(nblocks).unwrap();
        let greedy_victim_policy = GreedyVictimPolicy {};
        let root_key = AeadKey::random();

        let disk = SwornDisk::create(mem_disk, root_key, None, true, None).unwrap();
        let gc_worker = disk
            .create_gc_worker(Arc::new(greedy_victim_policy))
            .unwrap();

        // write enough blocks to trigger gc,[0-249] blocks are invalid, [250-550] will be migrated
        for i in 0..300 {
            let content: Vec<u8> = vec![1 as u8; BLOCK_SIZE];
            let mut buf = Buf::alloc(1).unwrap();
            buf.as_mut_slice().copy_from_slice(&content);
            disk.write(i, buf.as_ref()).unwrap();
        }
        disk.sync().unwrap();

        for i in 0..250 {
            let content: Vec<u8> = vec![i as u8; BLOCK_SIZE];
            let mut buf = Buf::alloc(1).unwrap();
            buf.as_mut_slice().copy_from_slice(&content);
            disk.write(i, buf.as_ref()).unwrap();
        }
        disk.sync().unwrap();

        gc_worker.background_gc().unwrap();

        for i in 0..250 {
            let content: Vec<u8> = vec![i as u8; BLOCK_SIZE];
            let mut read_buf = Buf::alloc(1).unwrap();
            disk.read(i, read_buf.as_mut()).unwrap();
            assert_eq!(read_buf.as_slice(), content, "block {} is not migrated", i);
        }

        for i in 250..300 {
            let content: Vec<u8> = vec![1 as u8; BLOCK_SIZE];
            let mut read_buf = Buf::alloc(1).unwrap();
            disk.read(i, read_buf.as_mut()).unwrap();
            assert_eq!(read_buf.as_slice(), content, "block {} is not migrated", i);
        }

        // after gc, the block at offset 0 should be migrated to another segment
    }

    #[test]
    fn multi_segment_migration() {
        init_logger();
        let nblocks = 256 * SEGMENT_SIZE;
        let mem_disk = MemDisk::create(nblocks * 5 / 4).unwrap();
        let greedy_victim_policy = GreedyVictimPolicy {};
        let root_key = AeadKey::random();

        let disk = SwornDisk::create(mem_disk, root_key, None, true, None).unwrap();
        let gc_worker = disk
            .create_gc_worker(Arc::new(greedy_victim_policy))
            .unwrap();

        let num_writes = 50000;

        for i in 0..num_writes {
            let content: Vec<u8> = vec![i as u8; BLOCK_SIZE];
            let mut buf = Buf::alloc(1).unwrap();
            buf.as_mut_slice().copy_from_slice(&content);
            let block_id = gen_rnd_pos(nblocks, 1);
            disk.write(block_id, buf.as_ref()).unwrap();
        }
        disk.sync().unwrap();

        gc_worker.background_gc().unwrap();
    }
}

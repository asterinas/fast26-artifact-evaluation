use super::block_alloc::{AllocDiff, AllocTable};
use super::sworndisk::Hba;
use crate::layers::log::{TxLog, TxLogStore};
use crate::os::{BTreeMap, Mutex};
use crate::util::BitMap;
use crate::{prelude::*, BlockSet, Errno};
use core::mem::size_of;
use core::sync::atomic::{AtomicUsize, Ordering};
// Each segment contains 1024 blocks
pub const SEGMENT_SIZE: usize = 1024;
pub type SegmentId = usize;

// Currently Segment is not response for Block Alloc, it just records
// alloced hba and count the number of valid blocks in the Segment, which is used for GC

// Persistent data: SegmentId, valid_block, free_space
pub struct Segment {
    segment_id: SegmentId,
    // valid_block statistic all empty blocks and blocks that have been marked as allocated,
    // it's used for GC to choose victim segment, and is initialized with nblocks when segment is created
    // when a block is deallocated, valid_block is decremented
    // TODO: Currently, valid_block is only associated with block deallocation, we need to consider block reallocation
    valid_block: AtomicUsize,
    // bitmap of blocks in the segment
    bitmap: Arc<Mutex<BitMap>>,
    nblocks: usize,
    free_space: AtomicUsize,
}

impl Segment {
    pub fn new(segment_id: SegmentId, nblocks: usize, bitmap: Arc<Mutex<BitMap>>) -> Self {
        Self {
            valid_block: AtomicUsize::new(nblocks),
            bitmap,
            nblocks,
            free_space: AtomicUsize::new(nblocks),
            segment_id,
        }
    }
    pub fn segment_id(&self) -> SegmentId {
        self.segment_id
    }
    pub fn nblocks(&self) -> usize {
        self.nblocks
    }

    // num_valid_blocks is only related to block deallcation
    pub fn num_valid_blocks(&self) -> usize {
        self.valid_block.load(Ordering::Acquire)
    }

    // free_space is related to both block allocation and deallocation,
    // represent the number of empty blocks and deallocated blocks in the segment
    pub fn free_space(&self) -> usize {
        self.free_space.load(Ordering::Acquire)
    }

    pub fn num_invalid_blocks(&self) -> usize {
        self.nblocks - self.num_valid_blocks()
    }

    pub fn mark_alloc(&self) {
        self.free_space.fetch_sub(1, Ordering::Release);
    }

    pub fn mark_alloc_batch(&self, nblocks: usize) {
        self.free_space.fetch_sub(nblocks, Ordering::Release);
    }

    pub fn mark_deallocated(&self) {
        //  debug!("mark_deallocated: {}", self.segment_id);
        self.free_space.fetch_add(1, Ordering::Release);
        self.valid_block.fetch_sub(1, Ordering::Release);
    }

    pub fn mark_deallocated_batch(&self, nblocks: usize) {
        //   debug!("mark_deallocated_batch: {}", self.segment_id);
        self.free_space.fetch_add(nblocks, Ordering::Release);
        self.valid_block.fetch_sub(nblocks, Ordering::Release);
    }

    // All blocks that have been marked as allocated
    pub fn find_all_allocated_blocks(&self) -> Vec<Hba> {
        let lower_bound = self.segment_id * SEGMENT_SIZE;
        let upper_bound = lower_bound + self.nblocks;
        let mut valid_blocks = Vec::new();
        let guard = self.bitmap.lock();
        for idx in lower_bound..upper_bound {
            if !guard.test_bit(idx) {
                valid_blocks.push(idx);
            }
        }
        valid_blocks
    }

    // Find empty blocks and blocks that have been marked as deallocated,
    // this function is used for choosing target blocks in GC
    pub fn find_all_free_blocks(&self) -> Vec<Hba> {
        let lower_bound = self.segment_id * SEGMENT_SIZE;
        let upper_bound = lower_bound + self.nblocks;
        let mut free_blocks = Vec::new();
        let guard = self.bitmap.lock();
        for idx in lower_bound..upper_bound {
            if guard.test_bit(idx) {
                free_blocks.push(idx);
            }
        }
        free_blocks
    }

    pub fn clear_segment(&self) {
        self.valid_block.store(self.nblocks, Ordering::Release);
        self.free_space.store(self.nblocks, Ordering::Release);
    }
}

impl Segment {
    pub fn to_slice(&self, buf: &mut [u8]) -> Result<usize> {
        let valid_blocks = self.num_valid_blocks();
        let free_space = self.free_space();
        let data = [valid_blocks, free_space];
        let ser_len = postcard::to_slice::<[usize; 2]>(&data, buf)
            .map_err(|_| Error::with_msg(InvalidArgs, "serialize segment failed"))?
            .len();
        Ok(ser_len)
    }

    pub fn recover(
        segment_id: SegmentId,
        buf: &[u8],
        bitmap: Arc<Mutex<BitMap>>,
        nblocks: usize,
    ) -> Result<Self> {
        let ret = postcard::from_bytes::<[usize; 2]>(buf)
            .map_err(|_| Error::with_msg(InvalidArgs, "deserialize segment failed"))?;
        let valid_blocks = ret[0];
        let free_space = ret[1];
        Ok(Self {
            valid_block: AtomicUsize::new(valid_blocks),
            free_space: AtomicUsize::new(free_space),
            bitmap,
            nblocks,
            segment_id,
        })
    }

    pub fn ser_size() -> usize {
        size_of::<usize>() * 2
    }
}

pub fn recover_segment_table(
    capacity: usize,
    buf: &[u8],
    bitmap: Arc<Mutex<BitMap>>,
) -> Result<Vec<Segment>> {
    let mut segment_table = Vec::with_capacity(capacity);
    for idx in 0..capacity {
        let offset = idx * Segment::ser_size();
        let segment_buf = &buf[offset..offset + Segment::ser_size()];
        let segment = Segment::recover(idx, segment_buf, bitmap.clone(), SEGMENT_SIZE)?;
        segment_table.push(segment);
    }
    Ok(segment_table)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::mem::size_of;
    use hashbrown::HashSet;

    #[test]
    fn test_segment_alloc_table() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 1024)));
        let segment = Segment::new(0, 1024, bitmap);
        segment.mark_alloc();
        assert_eq!(segment.num_valid_blocks(), 1024);
    }

    #[test]
    fn test_segment_alloc_table_batch() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 20 * 1024)));
        let segment = Segment::new(0, 1024, bitmap);
        segment.mark_alloc_batch(10);
        assert_eq!(segment.num_valid_blocks(), 1024);
        assert_eq!(segment.free_space(), 1014);
        segment.mark_deallocated();
        assert_eq!(segment.num_valid_blocks(), 1023);
        assert_eq!(segment.free_space(), 1015);
    }

    #[test]
    fn find_free_and_allocated_blocks() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 3 * 1024)));
        {
            let mut guard = bitmap.lock();
            guard.set(0, false);
            guard.set(1, false);

            guard.set(1024, false);
            guard.set(1025, false);
            guard.set(1026, false);
        }

        let segments = vec![
            Segment::new(0, 1024, bitmap.clone()),
            Segment::new(1, 1024, bitmap.clone()),
            Segment::new(2, 1024, bitmap.clone()),
        ];

        assert_eq!(segments[0].find_all_free_blocks().len(), 1022);
        assert_eq!(segments[1].find_all_free_blocks().len(), 1021);
        assert_eq!(segments[2].find_all_free_blocks().len(), 1024);

        let free_set0: HashSet<Hba> = segments[0].find_all_free_blocks().into_iter().collect();
        let free_set1: HashSet<Hba> = segments[1].find_all_free_blocks().into_iter().collect();
        let free_set2: HashSet<Hba> = segments[2].find_all_free_blocks().into_iter().collect();
        assert_eq!(free_set0.len(), 1022);
        assert_eq!(free_set1.len(), 1021);
        assert_eq!(free_set2.len(), 1024);
        assert!(!free_set0.contains(&0));
        assert!(!free_set0.contains(&1));

        assert!(!free_set1.contains(&1024));
        assert!(!free_set1.contains(&1025));
        assert!(!free_set1.contains(&1026));

        assert_eq!(segments[0].find_all_allocated_blocks().len(), 2);
        assert_eq!(segments[1].find_all_allocated_blocks().len(), 3);
        assert_eq!(segments[2].find_all_allocated_blocks().len(), 0);
    }

    #[test]
    fn recover_segment() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 3 * 1024)));
        let segment = Segment::new(0, 1024, bitmap.clone());
        segment.mark_alloc();
        segment.mark_alloc();
        segment.mark_deallocated();
        // valid_blocks: 1023, free_space: 1023
        let mut buf = vec![0; 2 * size_of::<usize>()];
        segment.to_slice(&mut buf).unwrap();
        let recovered_segment = Segment::recover(0, &buf, bitmap, 1024).unwrap();
        assert_eq!(recovered_segment.num_valid_blocks(), 1023);
        assert_eq!(recovered_segment.free_space(), 1023);
    }

    #[test]
    fn recover_multi_segments() {
        let bitmap = Arc::new(Mutex::new(BitMap::repeat(true, 3 * 1024)));
        let segments = vec![
            Segment::new(0, 1024, bitmap.clone()),
            Segment::new(1, 1024, bitmap.clone()),
            Segment::new(2, 1024, bitmap.clone()),
        ];
        segments[0].mark_alloc_batch(2);
        segments[0].mark_deallocated();
        segments[1].mark_alloc_batch(3);
        segments[1].mark_deallocated();
        segments[2].mark_alloc_batch(4);

        let mut buf = vec![0; Segment::ser_size() * 3];
        for (idx, segment) in segments.iter().enumerate() {
            let offset = idx * Segment::ser_size();
            let segment_buf = &mut buf[offset..offset + Segment::ser_size()];
            segment.to_slice(segment_buf).unwrap();
        }
        let recovered_segments = recover_segment_table(3, buf.as_slice(), bitmap).unwrap();
        assert_eq!(recovered_segments.len(), 3);
        assert_eq!(recovered_segments[0].num_valid_blocks(), 1023);
        assert_eq!(recovered_segments[0].free_space(), 1023);
        assert_eq!(recovered_segments[1].num_valid_blocks(), 1023);
        assert_eq!(recovered_segments[1].free_space(), 1022);
        assert_eq!(recovered_segments[2].num_valid_blocks(), 1024);
        assert_eq!(recovered_segments[2].free_space(), 1020);
    }
}

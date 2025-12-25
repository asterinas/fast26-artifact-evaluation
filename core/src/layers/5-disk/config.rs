use super::gc::{GreedyVictimPolicy, VictimPolicy, VictimPolicyRef};
use crate::os::Arc;
use core::usize;

#[derive(Clone)]
pub struct Config {
    pub cache_size: usize,
    pub two_level_caching: bool,
    pub delayed_reclamation: bool,
    pub stat_waf: bool,
    pub stat_cost: bool,
    pub enable_gc: bool,
    pub victim_policy: Option<VictimPolicyRef>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cache_size: usize::MAX,
            two_level_caching: true,
            delayed_reclamation: true,
            stat_waf: false,
            stat_cost: false,
            enable_gc: false,
            victim_policy: None,
        }
    }
}

impl Config {
    /// Get the victim policy, using GreedyVictimPolicy as default
    pub fn get_victim_policy(&self) -> VictimPolicyRef {
        self.victim_policy
            .clone()
            .unwrap_or_else(|| Arc::new(GreedyVictimPolicy {}))
    }
}

use core::usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    pub cache_size: usize,
    pub two_level_caching: bool,
    pub delayed_reclamation: bool,
    pub stat_waf: bool,
    pub stat_cost: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cache_size: usize::MAX,
            two_level_caching: true,
            delayed_reclamation: true,
            stat_waf: false,
            stat_cost: false,
        }
    }
}



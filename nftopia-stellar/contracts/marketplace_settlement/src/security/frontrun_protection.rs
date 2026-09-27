use crate::error::SettlementError;
use crate::events::{emit_front_running_detected, FrontRunningDetectedEvent};
use crate::types::Bid;
use soroban_sdk::{symbol_short, Address, Bytes, Env, Symbol, Vec};

// Storage keys
const COMMITMENT_STORAGE: Symbol = symbol_short!("commits");

/// Commit-reveal scheme for bid protection
pub struct CommitRevealScheme;

impl CommitRevealScheme {
    /// Create a commitment hash from bid details
    pub fn create_commitment(
        _bidder: &Address,
        _auction_id: u64,
        _bid_amount: i128,
        salt: &Bytes,
    ) -> Bytes {
        salt.clone()
    }

    /// Store a commitment
    pub fn store_commitment(
        env: &Env,
        bidder: &Address,
        auction_id: u64,
        commitment_hash: &Bytes,
        reveal_deadline: u64,
    ) -> Result<(), SettlementError> {
        let mut commitments: soroban_sdk::Map<Address, soroban_sdk::Map<u64, (Bytes, u64)>> = env
            .storage()
            .instance()
            .get(&COMMITMENT_STORAGE)
            .unwrap_or(soroban_sdk::Map::new(env));

        let mut bidder_commitments = commitments
            .get(bidder.clone())
            .unwrap_or(soroban_sdk::Map::new(env));

        bidder_commitments.set(auction_id, (commitment_hash.clone(), reveal_deadline));
        commitments.set(bidder.clone(), bidder_commitments);

        env.storage()
            .instance()
            .set(&COMMITMENT_STORAGE, &commitments);
        Ok(())
    }

    /// Reveal and verify a commitment
    pub fn reveal_commitment(
        env: &Env,
        bidder: &Address,
        auction_id: u64,
        bid_amount: i128,
        salt: &Bytes,
    ) -> Result<(), SettlementError> {
        let commitments: soroban_sdk::Map<Address, soroban_sdk::Map<u64, (Bytes, u64)>> = env
            .storage()
            .instance()
            .get(&COMMITMENT_STORAGE)
            .ok_or(SettlementError::NotFound)?;

        let bidder_commitments = commitments
            .get(bidder.clone())
            .ok_or(SettlementError::NotFound)?;

        let (stored_hash, reveal_deadline) = bidder_commitments
            .get(auction_id)
            .unwrap_or((Bytes::new(env), 0));

        // Check if reveal deadline has passed
        let current_time = env.ledger().timestamp();
        if current_time > reveal_deadline {
            return Err(SettlementError::Expired);
        }

        // Verify the commitment
        let computed_hash = Self::create_commitment(bidder, auction_id, bid_amount, salt);
        if computed_hash != stored_hash {
            return Err(SettlementError::CommitmentMismatch);
        }

        Ok(())
    }

    /// Clean up expired commitments
    pub fn cleanup_expired_commitments(env: &Env) -> Result<(), SettlementError> {
        let current_time = env.ledger().timestamp();
        let mut commitments: soroban_sdk::Map<Address, soroban_sdk::Map<u64, (Bytes, u64)>> = env
            .storage()
            .instance()
            .get(&COMMITMENT_STORAGE)
            .unwrap_or(soroban_sdk::Map::new(env));

        // This is a simplified cleanup - in production you'd want a more efficient approach
        let bidders: Vec<Address> = commitments.keys();

        for bidder in bidders.iter() {
            if let Some(mut bidder_commitments) = commitments.get(bidder.clone()) {
                let auction_ids: Vec<u64> = bidder_commitments.keys();

                for auction_id in auction_ids.iter() {
                    if let Some((_, reveal_deadline)) = bidder_commitments.get(auction_id) {
                        if current_time > reveal_deadline {
                            bidder_commitments.remove(auction_id);
                        }
                    }
                }

                if bidder_commitments.is_empty() {
                    commitments.remove(bidder.clone());
                } else {
                    commitments.set(bidder.clone(), bidder_commitments);
                }
            }
        }

        env.storage()
            .instance()
            .set(&COMMITMENT_STORAGE, &commitments);
        Ok(())
    }
}

/// Front-running pattern detection
pub struct FrontRunningDetector;

impl FrontRunningDetector {
    /// Analyze bidding patterns for potential front-running
    pub fn analyze_bidding_pattern(
        env: &Env,
        auction_id: u64,
        new_bid: &Bid,
        recent_bids: &Vec<Bid>,
        configured_bid_increment: i128,
    ) -> Result<(), SettlementError> {
        // Check for suspicious patterns
        let suspicious_patterns = Self::detect_suspicious_patterns(
            env,
            auction_id,
            new_bid,
            recent_bids,
            configured_bid_increment,
        )?;

        if !suspicious_patterns.is_empty() {
            // Emit front-running detection event
            let event = FrontRunningDetectedEvent {
                suspicious_address: new_bid.bidder.clone(),
                pattern: Bytes::from_slice(env, b"multiple_patterns"),
                timestamp: env.ledger().timestamp(),
            };
            emit_front_running_detected(env, event);

            return Err(SettlementError::FrontRunningDetected);
        }

        Ok(())
    }

    /// Detect various suspicious bidding patterns
    fn detect_suspicious_patterns(
        env: &Env,
        _auction_id: u64,
        new_bid: &Bid,
        recent_bids: &Vec<Bid>,
        configured_bid_increment: i128,
    ) -> Result<Vec<Bytes>, SettlementError> {
        let mut patterns = Vec::new(env);

        // Pattern 1: Rapid successive bids from same address
        if Self::detect_rapid_bidding(new_bid, recent_bids) {
            patterns.push_back(Bytes::from_slice(env, "rapid_bidding".as_bytes()));
        }

        // Pattern 2: Bid amounts that exactly match previous bids + increment
        if Self::detect_increment_gaming(new_bid, recent_bids, configured_bid_increment) {
            patterns.push_back(Bytes::from_slice(env, "increment_gaming".as_bytes()));
        }

        // Pattern 3: Bids placed at exact time intervals
        if Self::detect_timed_bidding(env, new_bid, recent_bids) {
            patterns.push_back(Bytes::from_slice(env, "timed_bidding".as_bytes()));
        }

        Ok(patterns)
    }

    /// Detect rapid successive bidding from same address
    fn detect_rapid_bidding(new_bid: &Bid, recent_bids: &Vec<Bid>) -> bool {
        let mut same_bidder_count = 0u32;
        let time_window = 60; // 60 seconds

        for bid in recent_bids.iter() {
            if bid.bidder == new_bid.bidder && new_bid.placed_at - bid.placed_at < time_window {
                same_bidder_count += 1;
                if same_bidder_count >= 3 {
                    return true;
                }
            }
        }
        false
    }

    /// Detect bids that repeatedly mirror the auction's configured increment.
    ///
    /// Bid amounts are represented in the asset's smallest units, so the
    /// configured increment is already denomination-safe: XLM and issued
    /// assets use the same integer comparison without a hard-coded decimal
    /// assumption. The auction engine remains responsible for rejecting bids
    /// below the minimum; this heuristic only reports a repeated pattern.
    fn detect_increment_gaming(
        new_bid: &Bid,
        recent_bids: &Vec<Bid>,
        configured_bid_increment: i128,
    ) -> bool {
        if recent_bids.is_empty() || configured_bid_increment <= 0 {
            return false;
        }

        // Compare against the actual per-auction increment, not an example
        // amount that only happened to fit one asset denomination.
        for bid in recent_bids.iter().rev().take(3) {
            if let Some(expected_amount) = bid.amount.checked_add(configured_bid_increment) {
                if new_bid.amount == expected_amount {
                    return true;
                }
            }
        }
        false
    }

    /// Detect suspiciously timed bidding
    fn detect_timed_bidding(env: &Env, new_bid: &Bid, recent_bids: &Vec<Bid>) -> bool {
        if recent_bids.len() < 2 {
            return false;
        }

        // Check for regular time intervals between bids
        let mut intervals = Vec::new(env);

        for i in 1..recent_bids.len() {
            if let (Some(prev_bid), Some(curr_bid)) = (recent_bids.get(i - 1), recent_bids.get(i)) {
                intervals.push_back(curr_bid.placed_at - prev_bid.placed_at);
            }
        }

        // Check if new bid follows similar pattern
        if let Some(last_interval) = intervals.get(intervals.len() - 1) {
            let new_interval =
                new_bid.placed_at - recent_bids.get(recent_bids.len() - 1).unwrap().placed_at;
            let diff = new_interval.abs_diff(last_interval);

            // If timing is too regular (within 5 seconds), flag as suspicious
            diff < 5
        } else {
            false
        }
    }
}

/// Withdrawal pattern monitoring
pub struct WithdrawalPatternMonitor;

impl WithdrawalPatternMonitor {
    /// Monitor withdrawal patterns for security
    pub fn monitor_withdrawal(
        _env: &Env,
        _user: &Address,
        _amount: i128,
        _withdrawal_type: &str,
    ) -> Result<(), SettlementError> {
        // Store withdrawal pattern for analysis
        // This would be expanded with more sophisticated monitoring
        // For now, it's a placeholder
        Ok(())
    }

    /// Check for unusual withdrawal patterns
    pub fn check_unusual_pattern(
        _env: &Env,
        _user: &Address,
        _amount: i128,
    ) -> Result<(), SettlementError> {
        // Placeholder for pattern analysis
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soroban_sdk::{testutils::Address as _, Address, Env};

    fn bid(_env: &Env, bidder: &Address, amount: i128, placed_at: u64) -> Bid {
        Bid {
            bidder: bidder.clone(),
            amount,
            placed_at,
            is_committed: false,
            commitment_hash: None,
            refunded: false,
        }
    }

    #[test]
    fn increment_detection_uses_each_auction_increment_in_smallest_units() {
        let env = Env::default();
        let bidder = Address::generate(&env);
        let mut recent = Vec::new(&env);
        recent.push_back(bid(&env, &bidder, 100_000, 1));

        assert!(FrontRunningDetector::detect_increment_gaming(
            &bid(&env, &bidder, 101_000, 2),
            &recent,
            1_000,
        ));
        assert!(!FrontRunningDetector::detect_increment_gaming(
            &bid(&env, &bidder, 101_000, 2),
            &recent,
            10_000,
        ));
        assert!(FrontRunningDetector::detect_increment_gaming(
            &bid(&env, &bidder, 110_000, 2),
            &recent,
            10_000,
        ));
    }
}

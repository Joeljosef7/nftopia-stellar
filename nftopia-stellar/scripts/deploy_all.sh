#!/bin/bash
# Builds, deploys and initializes all NFTopia Stellar contracts, recording each
# deployment in deployments/manifest.json and verifying each initialization.
#
# Usage: NETWORK=testnet SOURCE=secret ./scripts/deploy_all.sh
#
# Initialization is configured per contract and per network through the
# environment; every value below has a working default so a plain testnet run
# needs no extra setup.
#
#   ADMIN_ADDRESS    identity used as admin; defaults to `soroban config
#                    identity address $SOURCE`
#   FEE_ASSET        token contract the factory charges fees in; defaults to
#                    the admin identity (safe while FactoryFee is 0, which is
#                    the value initialize() sets — see the warning below)
#   COLLECTION_NAME / COLLECTION_BASE_URI
#   COLLECTION_SYMBOL / COLLECTION_MAX_SUPPLY
#                    nft_contract CollectionConfig; max_supply must be
#                    1..=1000000 or initialize() rejects it with
#                    SupplyCapTooLow/TooHigh
#   MINT_PRICE       i128, or empty for None
#   PLATFORM_FEE_BPS marketplace_settlement fee; must be <= 10000
#   MINIMUM_FEE / MAXIMUM_FEE
#                    i128; when MAXIMUM_FEE > 0 it must exceed MINIMUM_FEE
#   FEE_RECIPIENT    address receiving settlement fees; defaults to admin
#
# Fails loudly: any failed initialization or verification aborts the run with a
# non-zero exit and a message naming the contract, contract ID and network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC2046 # .env is expected to be simple KEY=VALUE pairs
    export $(grep -v '^#' .env | xargs)
    set +a
fi

NETWORK=${NETWORK:-testnet}
SOURCE=${SOURCE:-secret}

GIT_COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIMESTAMP=$(date -u +%s)
export GIT_COMMIT_HASH BUILD_TIMESTAMP

CONTRACTS=(collection_factory nft_contract marketplace_settlement transaction_contract)

die() {
    echo "" >&2
    echo "ERROR: $*" >&2
    exit 1
}

# require_int <name> <value> [min] [max]
# Rejects anything the contract or the shell arithmetic would choke on, before
# a single WASM is built, so a typo cannot abort a run halfway through.
require_int() {
    local NAME="$1" VALUE="$2" MIN="${3:-}" MAX="${4:-}"
    local DIGITS="${VALUE#-}"     # i128 fields may be negative

    case "$DIGITS" in
        ''|*[!0-9]*) die "$NAME must be an integer, got '$VALUE'" ;;
    esac
    if [ -n "$MIN" ] && [ "$VALUE" -lt "$MIN" ] 2>/dev/null; then
        die "$NAME must be >= $MIN, got '$VALUE'"
    fi
    if [ -n "$MAX" ] && [ "$VALUE" -gt "$MAX" ] 2>/dev/null; then
        die "$NAME must be <= $MAX, got '$VALUE'"
    fi
}

for REQUIRED in soroban cargo; do
    command -v "$REQUIRED" >/dev/null 2>&1 \
        || die "required command '$REQUIRED' not found on PATH"
done

# Resolve the admin identity once, before anything is deployed. A bad identity
# should stop the run here rather than after contracts are already on-chain.
ADMIN_ADDRESS=${ADMIN_ADDRESS:-$(soroban config identity address "$SOURCE" 2>/dev/null || true)}
[ -n "$ADMIN_ADDRESS" ] \
    || die "could not resolve an admin address for identity '$SOURCE'.
       Create one with 'soroban keys new <name>' or set ADMIN_ADDRESS."

# ---------------------------------------------------------------------------
# Per-contract initialization parameters
# ---------------------------------------------------------------------------

# collection_factory stores fee_asset and uses it as a token client whenever a
# fee is charged. initialize() sets FactoryFee to 0, so nothing touches this
# address during deployment — but fees will break until it points at a real
# token contract, so say so out loud rather than silently.
if [ -z "${FEE_ASSET:-}" ]; then
    FEE_ASSET="$ADMIN_ADDRESS"
    echo "WARNING: FEE_ASSET is not set; defaulting it to the admin identity."
    echo "         Fine for a testnet deploy (FactoryFee starts at 0), but set"
    echo "         FEE_ASSET to a real token contract before enabling fees."
fi

# nft_contract: CollectionConfig is mandatory — every field is required by the
# contract, and max_supply is validated against 1..=1000000.
COLLECTION_NAME=${COLLECTION_NAME:-NFTopia}
COLLECTION_SYMBOL=${COLLECTION_SYMBOL:-NFTP}
COLLECTION_BASE_URI=${COLLECTION_BASE_URI:-ipfs://}
COLLECTION_MAX_SUPPLY=${COLLECTION_MAX_SUPPLY:-10000}
require_int COLLECTION_MAX_SUPPLY "$COLLECTION_MAX_SUPPLY" 1 1000000

# marketplace_settlement: FeeConfig validation rejects bps above 10000 and a
# minimum_fee that is not below maximum_fee whenever maximum_fee is positive.
PLATFORM_FEE_BPS=${PLATFORM_FEE_BPS:-250}
MINIMUM_FEE=${MINIMUM_FEE:-0}
MAXIMUM_FEE=${MAXIMUM_FEE:-0}
FEE_RECIPIENT=${FEE_RECIPIENT:-$ADMIN_ADDRESS}

require_int PLATFORM_FEE_BPS "$PLATFORM_FEE_BPS" 0 10000
require_int MINIMUM_FEE "$MINIMUM_FEE"
require_int MAXIMUM_FEE "$MAXIMUM_FEE"

if [ "$MAXIMUM_FEE" -gt 0 ] && [ "$MINIMUM_FEE" -ge "$MAXIMUM_FEE" ]; then
    die "MINIMUM_FEE ($MINIMUM_FEE) must be below MAXIMUM_FEE ($MAXIMUM_FEE)"
fi

# Optional i128 mint price; empty means None.
MINT_PRICE_JSON=null
if [ -n "${MINT_PRICE:-}" ]; then
    require_int MINT_PRICE "$MINT_PRICE"
    MINT_PRICE_JSON="$MINT_PRICE"
fi

collection_config_json() {
    printf '{"name":"%s","symbol":"%s","base_uri":"%s","max_supply":%s,"mint_price":%s,"is_revealed":false,"metadata_is_frozen":false}' \
        "$COLLECTION_NAME" "$COLLECTION_SYMBOL" "$COLLECTION_BASE_URI" \
        "$COLLECTION_MAX_SUPPLY" "$MINT_PRICE_JSON"
}

fee_config_json() {
    printf '{"platform_fee_bps":%s,"minimum_fee":%s,"maximum_fee":%s,"fee_recipient":"%s","dynamic_fee_enabled":false,"volume_discounts":[],"vip_exemptions":[]}' \
        "$PLATFORM_FEE_BPS" "$MINIMUM_FEE" "$MAXIMUM_FEE" "$FEE_RECIPIENT"
}

# ---------------------------------------------------------------------------
# Deploy, initialize, verify
# ---------------------------------------------------------------------------

# Prints the entry point that reports $1's post-deploy state, or nothing when
# the contract has no usable one. Verification is only as strong as the entry
# point allows:
#
#   * genuine  - the getter reads state initialize() wrote and errors
#                (NotFound) when that state is absent, so a successful call
#                proves initialization.
#   * liveness - every view on this contract falls back to unwrap_or(default),
#                so it answers identically before and after initialize(). The
#                call still proves the instance is deployed and answering;
#                initialization itself is proven by initialize() returning 0,
#                which the contract's AlreadyInitialized guard makes a one-shot
#                event. A read-only get_admin() would close this gap - see PR.
#   * n/a      - the contract has no initialize() entry point at all.
initializer_for() {
    case "$1" in
        # initialize(admin, fee_asset) writes FactoryAdmin + counters. No view
        # reads FactoryAdmin back: get_collection_count()/get_max_collections()
        # both unwrap_or() the very values initialize() writes.
        collection_factory)     echo "get_collection_count liveness" ;;

        # initialize() writes CollectionConfig; get_max_supply() reads it with
        # .ok_or(ContractError::NotFound), so it fails until initialized.
        nft_contract)           echo "get_max_supply genuine" ;;

        # initialize() writes SWAP_TIMEOUT_CFG, but timeout_config() reads it
        # with unwrap_or_else(defaults) - and we pass null, i.e. defaults.
        marketplace_settlement) echo "get_swap_timeout_config liveness" ;;

        # No initialize() entry point exists on this contract (confirmed
        # against its WASM spec: 0 initialize functions). get_version()
        # proves it is live.
        transaction_contract)   echo "get_version n/a" ;;
    esac
}

initialize_contract() {
    local CONTRACT="$1"
    local CONTRACT_ID="$2"
    local -a invoke_args

    case "$CONTRACT" in
        collection_factory)
            invoke_args=(initialize --admin "$ADMIN_ADDRESS" --fee_asset "$FEE_ASSET") ;;
        nft_contract)
            invoke_args=(initialize
                --admin "$ADMIN_ADDRESS"
                --config "$(collection_config_json)"
                --default_royalty null) ;;
        marketplace_settlement)
            invoke_args=(initialize
                --admin "$ADMIN_ADDRESS"
                --fee_config "$(fee_config_json)"
                --swap_timeout_config null) ;;
        transaction_contract)
            echo "  Skipping initialize: $CONTRACT exposes no initialize entry point."
            return 0 ;;
        *)
            die "no initialize mapping for contract '$CONTRACT' — update this script" ;;
    esac

    echo "  Initializing $CONTRACT..."
    if ! soroban contract invoke \
        --id "$CONTRACT_ID" \
        --source "$SOURCE" \
        --network "$NETWORK" \
        -- "${invoke_args[@]}"; then
        echo "" >&2
        echo "ERROR: initialize failed for $CONTRACT ($CONTRACT_ID on $NETWORK)." >&2
        echo "       The contract is deployed but NOT usable. Nothing further was run." >&2
        return 1
    fi
    echo "  Initialized: $CONTRACT"
}

verify_initialized() {
    local CONTRACT="$1"
    local CONTRACT_ID="$2"
    local ENTRY FN KIND RESPONSE

    ENTRY=$(initializer_for "$CONTRACT")
    [ -n "$ENTRY" ] || die "no verification entry point mapped for '$CONTRACT'"
    FN="${ENTRY%% *}"
    KIND="${ENTRY##* }"

    case "$KIND" in
        genuine) echo "  Verifying $CONTRACT is initialized via $FN..." ;;
        n/a)     echo "  Checking $CONTRACT is live via $FN (no initialize entry point)..." ;;
        *)       echo "  Checking $CONTRACT is live via $FN (liveness only; initialize() already proved init)" ;;
    esac

    if ! RESPONSE=$(soroban contract invoke \
        --id "$CONTRACT_ID" \
        --source "$SOURCE" \
        --network "$NETWORK" \
        -- "$FN" 2>&1); then
        echo "" >&2
        echo "ERROR: post-initialization verification failed for $CONTRACT" >&2
        echo "       ($CONTRACT_ID on $NETWORK, call: $FN)" >&2
        echo "       $RESPONSE" >&2
        return 1
    fi
    echo "  Verified: $FN -> $RESPONSE"
}

deploy_contract() {
    local CONTRACT="$1"
    local WASM="target/wasm32-unknown-unknown/release/${CONTRACT}.wasm"

    echo ""
    echo "--- Deploying $CONTRACT ---"

    WASM_HASH=$(soroban contract install \
        --wasm "$WASM" \
        --source "$SOURCE" \
        --network "$NETWORK")
    echo "  WASM Hash: $WASM_HASH"

    CONTRACT_ID=$(soroban contract deploy \
        --wasm-hash "$WASM_HASH" \
        --source "$SOURCE" \
        --network "$NETWORK")
    echo "  Contract ID: $CONTRACT_ID"

    # Order matters: initialize before recording, and verify after both, so the
    # manifest only ever describes a contract that has initialized cleanly.
    initialize_contract "$CONTRACT" "$CONTRACT_ID"
    verify_initialized "$CONTRACT" "$CONTRACT_ID"

    "$SCRIPT_DIR/deployment_manifest.sh" "$CONTRACT" "$CONTRACT_ID" "$WASM_HASH" "$NETWORK"
}

echo "Building all contracts (git=$GIT_COMMIT_HASH, ts=$BUILD_TIMESTAMP, network=$NETWORK)..."
for CONTRACT in "${CONTRACTS[@]}"; do
    cargo build --target wasm32-unknown-unknown --release --package "$CONTRACT"
done

echo ""
echo "Initializing as admin $ADMIN_ADDRESS on $NETWORK"

for CONTRACT in "${CONTRACTS[@]}"; do
    deploy_contract "$CONTRACT"
done

echo ""
echo "All contracts deployed, initialized and verified."
echo "Manifest updated at deployments/manifest.json"
echo ""
echo "Contract addresses for $NETWORK:"
python3 - "$NETWORK" <<'PY'
from json import load
import sys
network = sys.argv[1]
with open("deployments/manifest.json") as f:
    manifest = load(f)
for entry in manifest.get("deployments", []):
    if entry.get("network") == network:
        print(f"  {entry['contract']}: {entry['contract_id']}")
PY
echo ""
echo "Share these addresses with backend/frontend/mobile teams."

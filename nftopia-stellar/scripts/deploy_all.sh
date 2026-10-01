#!/bin/bash
# Builds and deploys all NFTopia Stellar contracts, wires the cross-contract
# dependencies (marketplace_settlement <--> nft_contract), verifies the wiring
# by reading the configured addresses back from the contracts, and records each
# deployment in deployments/manifest.json.
#
# Usage: NETWORK=testnet SOURCE=mykey ./scripts/deploy_all.sh
#
# The cross-contract dependency graph is documented in
# docs/deployment-wiring.md; the wiring step below registers the freshly
# deployed nft_contract address with marketplace_settlement so that settlement
# logic can resolve and transfer NFTs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

NETWORK=${NETWORK:-testnet}
SOURCE=${SOURCE:-secret}

# --- Network configuration ----------------------------------------------------
# Default RPC endpoint / passphrase per network; override with RPC_URL and
# NETWORK_PASSPHRASE if you use a different provider.
case "$NETWORK" in
    testnet)
        DEFAULT_RPC_URL="https://soroban-testnet.stellar.org:443"
        DEFAULT_PASSPHRASE="Test SDF Network ; September 2015"
        ;;
    mainnet)
        DEFAULT_RPC_URL="https://soroban-rpc.stellar.org"
        DEFAULT_PASSPHRASE="Public Global Stellar Network ; September 2015"
        ;;
    *)
        echo "ERROR: unsupported NETWORK '$NETWORK' (expected testnet or mainnet)" >&2
        exit 1
        ;;
esac
RPC_URL=${RPC_URL:-$DEFAULT_RPC_URL}
NETWORK_PASSPHRASE=${NETWORK_PASSPHRASE:-$DEFAULT_PASSPHRASE}

# --- CLI detection ------------------------------------------------------------
# Official toolchain is stellar-cli (binary `stellar`); a legacy `soroban` CLI is
# supported as a fallback. See README.md -> Prerequisites.
if command -v stellar >/dev/null 2>&1; then
    CLI=stellar
elif command -v soroban >/dev/null 2>&1; then
    CLI=soroban
else
    echo "ERROR: no Stellar CLI found. Install stellar-cli: cargo install --locked stellar-cli" >&2
    exit 1
fi
echo "Using CLI: $CLI (network=$NETWORK, rpc=$RPC_URL, source=$SOURCE)"

# resolve the deployer/admin account address
if [ "$CLI" = "stellar" ]; then
    ADMIN_ADDR=$("$CLI" keys public-key "$SOURCE" 2>/dev/null) || {
        echo "ERROR: identity '$SOURCE' not found. Add it with: stellar keys add $SOURCE" >&2
        exit 1
    }
else
    ADMIN_ADDR=$("$CLI" config identity address "$SOURCE" 2>/dev/null) || {
        echo "ERROR: identity '$SOURCE' not found." >&2
        exit 1
    }
fi
echo "Admin/deployer address: $ADMIN_ADDR"

export GIT_COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
export BUILD_TIMESTAMP=$(date -u +%s)

CONTRACTS=(collection_factory nft_contract marketplace_settlement transaction_contract)

echo "Building all contracts (git=$GIT_COMMIT_HASH, ts=$BUILD_TIMESTAMP, network=$NETWORK)..."
for CONTRACT in "${CONTRACTS[@]}"; do
    cargo build --target wasm32-unknown-unknown --release --package "$CONTRACT"
done

# invoke_contract <contract_id> <function> [arg value ...]
invoke_contract() {
    local ID="$1" FN="$2"
    shift 2
    if [ "$CLI" = "stellar" ]; then
        "$CLI" contract invoke --id "$ID" --source-account "$SOURCE" \
            --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE" -- "$FN" "$@"
    else
        "$CLI" contract invoke --id "$ID" --source "$SOURCE" --network "$NETWORK" -- "$FN" "$@"
    fi
}

deploy_contract() {
    local CONTRACT="$1"
    local WASM="target/wasm32-unknown-unknown/release/${CONTRACT}.wasm"

    echo ""
    echo "--- Deploying $CONTRACT ---"

    if [ "$CLI" = "stellar" ]; then
        WASM_HASH=$("$CLI" contract upload --wasm "$WASM" --source-account "$SOURCE" \
            --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE")
    else
        WASM_HASH=$("$CLI" contract install --wasm "$WASM" --source "$SOURCE" --network "$NETWORK")
    fi
    echo "  WASM Hash: $WASM_HASH"

    if [ "$CLI" = "stellar" ]; then
        CONTRACT_ID=$("$CLI" contract deploy --wasm-hash "$WASM_HASH" --source-account "$SOURCE" \
            --rpc-url "$RPC_URL" --network-passphrase "$NETWORK_PASSPHRASE")
    else
        CONTRACT_ID=$("$CLI" contract deploy --wasm-hash "$WASM_HASH" --source "$SOURCE" --network "$NETWORK")
    fi
    echo "  Contract ID: $CONTRACT_ID"

    "$SCRIPT_DIR/deployment_manifest.sh" "$CONTRACT" "$CONTRACT_ID" "$WASM_HASH" "$NETWORK"

    echo "  Verifying $CONTRACT is live on $NETWORK"
    if ! invoke_contract "$CONTRACT_ID" get_admin > /dev/null 2>&1; then
        echo "  Warning: get_admin verification call failed for $CONTRACT (check function name/admin init)"
    else
        echo "  Verified: $CONTRACT responds to get_admin"
    fi
}

for CONTRACT in "${CONTRACTS[@]}"; do
    deploy_contract "$CONTRACT"
done

# manifest_id <contract> -> the contract_id recorded for $NETWORK
manifest_id() {
    python3 - "$NETWORK" "$1" <<'PY'
from json import load
import sys
network, contract = sys.argv[1], sys.argv[2]
with open("deployments/manifest.json") as f:
    manifest = load(f)
for entry in manifest.get("deployments", []):
    if entry.get("network") == network and entry.get("contract") == contract:
        print(entry["contract_id"])
        break
PY
}

NFT_CONTRACT_ID=$(manifest_id nft_contract)
COLLECTION_FACTORY_ID=$(manifest_id collection_factory)
MARKETPLACE_ID=$(manifest_id marketplace_settlement)
TRANSACTION_CONTRACT_ID=$(manifest_id transaction_contract)

echo ""
echo "=== Cross-contract wiring ==="
echo "  marketplace_settlement: $MARKETPLACE_ID"
echo "  nft_contract:           $NFT_CONTRACT_ID"
echo "  collection_factory:     $COLLECTION_FACTORY_ID"
echo "  transaction_contract:   $TRANSACTION_CONTRACT_ID"
echo "  (dependency graph: see docs/deployment-wiring.md)"

# ---------------------------------------------------------------------------
# Step 1: Initialize contracts that require it before they can be wired.
# The admin-guarded wiring calls below depend on `admin_cfg`, which is only
# created by `initialize`, so this must happen first. Both calls are
# idempotent-friendly: re-running on an already-initialized contract is
# detected and reported instead of failing the script.
# ---------------------------------------------------------------------------

echo ""
echo "--- Initializing contracts ---"

# collection_factory.initialize(admin, fee_asset)
if [ -n "${FEE_ASSET:-}" ]; then
    echo "  Initializing collection_factory (fee_asset=$FEE_ASSET)..."
    if INIT_OUT=$(invoke_contract "$COLLECTION_FACTORY_ID" initialize --admin "$ADMIN_ADDR" --fee_asset "$FEE_ASSET" 2>&1); then
        echo "    collection_factory initialized"
    elif printf '%s' "$INIT_OUT" | grep -qi "already.initialized"; then
        echo "    collection_factory already initialized (continuing)"
    else
        echo "$INIT_OUT"
        echo "ERROR: collection_factory.initialize failed. Set FEE_ASSET to the token SAC the" >&2
        echo "       factory collects overflow fees in (e.g. the network XLM SAC)." >&2
        exit 1
    fi
else
    echo "  Skipping collection_factory init (set FEE_ASSET to the token SAC address, e.g. the"
    echo "  network XLM SAC, to initialize it)."
fi

# marketplace_settlement.initialize(admin, fee_config, swap_timeout_config=None)
FEE_CONFIG_JSON=${FEE_CONFIG_JSON:-"{\"platform_fee_bps\":250,\"minimum_fee\":1000,\"maximum_fee\":1000000,\"fee_recipient\":\"$ADMIN_ADDR\",\"dynamic_fee_enabled\":false,\"volume_discounts\":[],\"vip_exemptions\":[]}"}
echo "  Initializing marketplace_settlement..."
if INIT_OUT=$(invoke_contract "$MARKETPLACE_ID" initialize --admin "$ADMIN_ADDR" --fee_config "$FEE_CONFIG_JSON" 2>&1); then
    echo "    marketplace_settlement initialized"
elif printf '%s' "$INIT_OUT" | grep -qi "already.initialized"; then
    echo "    marketplace_settlement already initialized (continuing)"
else
    echo "$INIT_OUT"
    echo "ERROR: marketplace_settlement.initialize failed; cross-contract wiring is impossible" >&2
    echo "       without an initialized admin config. Fix the fee config and re-run." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Wire marketplace_settlement -> nft_contract.
# Registers the freshly deployed nft_contract address as an allowed NFT
# contract. The call is idempotent (it simply re-sets the flag to true), so
# this step is safe to re-run.
# ---------------------------------------------------------------------------

echo ""
echo "--- Wiring marketplace_settlement -> nft_contract ---"
if invoke_contract "$MARKETPLACE_ID" add_allowed_nft_contract --admin "$ADMIN_ADDR" --contract "$NFT_CONTRACT_ID"; then
    echo "  Registered NFT contract $NFT_CONTRACT_ID with marketplace_settlement"
else
    echo "ERROR: add_allowed_nft_contract call failed." >&2
    exit 1
fi

# Optional additional wiring for settlement assets (external SACs, not part of
# this deploy): WIRE_FEE_ASSET registers a token via add_supported_asset and
# WIRE_XLM_SAC configures the native XLM Stellar Asset Contract.
if [ -n "${WIRE_FEE_ASSET:-}" ]; then
    SYMBOL=${WIRE_FEE_ASSET_SYMBOL:-XLM}
    echo "  Registering fee asset $WIRE_FEE_ASSET ($SYMBOL) via add_supported_asset..."
    invoke_contract "$MARKETPLACE_ID" add_supported_asset --admin "$ADMIN_ADDR" \
        --asset "{\"Token\":{\"contract\":\"$WIRE_FEE_ASSET\",\"symbol\":\"$SYMBOL\"}}"
fi

if [ -n "${WIRE_XLM_SAC:-}" ]; then
    echo "  Configuring native XLM SAC $WIRE_XLM_SAC..."
    invoke_contract "$MARKETPLACE_ID" set_native_xlm_sac --admin "$ADMIN_ADDR" --native_xlm_sac "$WIRE_XLM_SAC"
fi

# ---------------------------------------------------------------------------
# Step 3: Verification — read the configured addresses back from the contracts
# and assert they match what was just deployed.
# ---------------------------------------------------------------------------

echo ""
echo "--- Verifying wiring ---"

ALLOWED=$(invoke_contract "$MARKETPLACE_ID" is_nft_allowed --contract "$NFT_CONTRACT_ID")
echo "  marketplace_settlement.is_nft_allowed($NFT_CONTRACT_ID) = $ALLOWED"
if [ "$ALLOWED" != "true" ]; then
    echo "ERROR: wiring verification failed — nft_contract is NOT allowlisted." >&2
    exit 1
fi

if [ -n "${WIRE_FEE_ASSET:-}" ]; then
    SUPPORTED=$(invoke_contract "$MARKETPLACE_ID" get_supported_assets)
    echo "  marketplace_settlement.get_supported_assets() = $SUPPORTED"
    if ! printf '%s' "$SUPPORTED" | grep -q "$WIRE_FEE_ASSET"; then
        echo "ERROR: verification failed — $WIRE_FEE_ASSET is not in the supported assets." >&2
        exit 1
    fi
fi

if [ -n "${WIRE_XLM_SAC:-}" ]; then
    CONFIGURED_SAC=$(invoke_contract "$MARKETPLACE_ID" get_native_xlm_sac)
    echo "  marketplace_settlement.get_native_xlm_sac() = $CONFIGURED_SAC"
    if ! printf '%s' "$CONFIGURED_SAC" | grep -q "$WIRE_XLM_SAC"; then
        echo "ERROR: verification failed — native XLM SAC not configured." >&2
        exit 1
    fi
fi

echo ""
echo "All contracts deployed and wired. Manifest updated at deployments/manifest.json"
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
echo "Wiring summary: marketplace_settlement ($MARKETPLACE_ID) is configured with"
echo "nft_contract ($NFT_CONTRACT_ID). Share these addresses with backend/frontend/mobile teams."
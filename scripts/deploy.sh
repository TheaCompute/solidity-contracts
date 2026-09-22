#!/usr/bin/env bash
# deploy.sh - Deploy the full TheaCompute contract suite to Robinhood Chain testnet.
#
# Prerequisites:
#   - Foundry installed (foundryup)
#   - DEPLOYER_KEY env var set to a funded testnet private key
#     (get testnet ETH via ./scripts/airdrop_testnet.sh guidance)
#   - Optional: USDG_ADDRESS / THEACOMPUTE_ADDRESS to reuse existing tokens
#
# Usage:
#   ./scripts/deploy.sh [--skip-build] [--dry-run]

set -euo pipefail
cd "$(dirname "$0")/.."

RPC_URL="${RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
EXPECTED_CHAIN_ID=46630

DRY_RUN=false
SKIP_BUILD=false

for arg in "$@"; do
  case $arg in
    --dry-run)    DRY_RUN=true   ;;
    --skip-build) SKIP_BUILD=true ;;
  esac
done

echo "==> TheaCompute testnet deployment"
echo "    rpc:      $RPC_URL"
echo "    dry-run:  $DRY_RUN"
echo ""

FORGE_VERSION=$(forge --version 2>/dev/null | head -1 || echo "not found")
echo "    forge:    $FORGE_VERSION"
if [[ "$FORGE_VERSION" == "not found" ]]; then
  echo "Error: Foundry not installed. Run: curl -L https://foundry.paradigm.xyz | bash && foundryup"
  exit 1
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [[ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
  echo "Error: RPC reports chain ID $CHAIN_ID, expected $EXPECTED_CHAIN_ID (Robinhood Chain testnet)."
  exit 1
fi

: "${DEPLOYER_KEY:?Set DEPLOYER_KEY to the deployer private key}"
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
BALANCE_WEI=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
echo "    deployer: $DEPLOYER"
echo "    balance:  $(cast from-wei "$BALANCE_WEI") ETH"

if [[ $(echo "$BALANCE_WEI < 10000000000000000" | bc) -eq 1 ]]; then
  echo ""
  echo "Warning: balance below 0.01 ETH. See ./scripts/airdrop_testnet.sh for faucet guidance."
fi

echo ""

if [[ "$SKIP_BUILD" == "false" ]]; then
  echo "==> Building contracts..."
  forge build
  echo ""
fi

BROADCAST_FLAG="--broadcast"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> [dry-run] simulating deployment (no transactions broadcast)"
  BROADCAST_FLAG=""
fi

forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  $BROADCAST_FLAG -vvv

echo ""
echo "==> Deployment complete."
echo ""
echo "Next steps:"
echo "  1. Record the printed contract addresses in the README table."
echo "  2. Optionally seed demo state: forge script script/Seed.s.sol --rpc-url $RPC_URL --broadcast --private-key \$DEPLOYER_KEY (with the env vars printed above)."
echo "  3. Run the suite against testnet: forge test --fork-url $RPC_URL"
echo "  4. Before mainnet: replace ARBITRATOR in src/Settlement.sol with the real Safe multisig."
echo "  5. Before mainnet: replace CRANK_OPERATOR in src/Staking.sol with the real crank operator."

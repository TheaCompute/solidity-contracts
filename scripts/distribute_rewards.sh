#!/usr/bin/env bash
# distribute_rewards.sh - Funds a new reward epoch on RewardDistributor from the
# operator's USDG balance, snapshotting the current total weighted stake.
#
# Intended to run once per reward cycle (e.g. weekly via cron) by the treasury
# operator. The operator wallet must hold the USDG being distributed and have
# approved the distributor, and must own the RewardDistributor contract.
#
# Usage:
#   REWARD_USDG=5000000000 \        # USDG base units (6 decimals) to distribute
#   DISTRIBUTOR=0x... STAKING=0x... USDG=0x... DEPLOYER_KEY=0x... \
#   ./scripts/distribute_rewards.sh

set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
: "${DISTRIBUTOR:?Set DISTRIBUTOR to the RewardDistributor address}"
: "${STAKING:?Set STAKING to the Staking contract address}"
: "${USDG:?Set USDG to the USDG token address}"
: "${DEPLOYER_KEY:?Set DEPLOYER_KEY to the operator private key}"
: "${REWARD_USDG:?Set REWARD_USDG to the USDG base-unit amount to distribute}"

OPERATOR=$(cast wallet address --private-key "$DEPLOYER_KEY")
TOTAL_WEIGHTED=$(cast call "$STAKING" "totalWeightedStake()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
LAST_EPOCH=$(cast call "$DISTRIBUTOR" "currentEpoch()(uint64)" --rpc-url "$RPC_URL" | awk '{print $1}')
NEXT_EPOCH=$((LAST_EPOCH + 1))

echo "Reward distribution"
echo "  operator:        $OPERATOR"
echo "  epoch:           $NEXT_EPOCH"
echo "  amount:          $REWARD_USDG USDG units"
echo "  weighted stake:  $TOTAL_WEIGHTED"
echo ""

if [[ "$TOTAL_WEIGHTED" == "0" ]]; then
  echo "No weighted stake — nothing to distribute."
  exit 0
fi

cast send "$USDG" "approve(address,uint256)" "$DISTRIBUTOR" "$REWARD_USDG" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" >/dev/null

cast send "$DISTRIBUTOR" "startEpoch(uint64,uint256,uint256)" \
  "$NEXT_EPOCH" "$REWARD_USDG" "$TOTAL_WEIGHTED" \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY"

echo ""
echo "Epoch $NEXT_EPOCH funded. Stakers can now claim pro-rata via claimReward($NEXT_EPOCH)."

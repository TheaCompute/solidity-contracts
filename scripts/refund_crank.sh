#!/usr/bin/env bash
# refund_crank.sh - Scans EscrowLocked events on JobEscrow and calls refundEscrow
# for any job past its expiry that is still Locked.
#
# Permissionless: any funded wallet can crank refunds once the 120s job timeout
# has elapsed. Intended to run as a keeper bot or scheduled job.
#
# Usage:
#   JOB_ESCROW=0x... DEPLOYER_KEY=0x... ./scripts/refund_crank.sh
#
# Env:
#   RPC_URL     (default: Robinhood Chain testnet)
#   FROM_BLOCK  (default: scan the last ~50,000 blocks)

set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
: "${JOB_ESCROW:?Set JOB_ESCROW to the JobEscrow contract address}"
: "${DEPLOYER_KEY:?Set DEPLOYER_KEY to the cranking wallet private key}"

LATEST=$(cast block-number --rpc-url "$RPC_URL")
FROM_BLOCK="${FROM_BLOCK:-$((LATEST > 50000 ? LATEST - 50000 : 0))}"
NOW=$(cast block latest --field timestamp --rpc-url "$RPC_URL")

# EscrowStatus: 0=None 1=Locked 2=Settled 3=Refunded
STATUS_LOCKED=1

echo "Scanning EscrowLocked events on $JOB_ESCROW (blocks $FROM_BLOCK..$LATEST)..."

EVENT_SIG="EscrowLocked(bytes32,address,uint256,uint8,uint64)"
JOB_IDS=$(cast logs --rpc-url "$RPC_URL" \
  --from-block "$FROM_BLOCK" --to-block "$LATEST" \
  --address "$JOB_ESCROW" "$EVENT_SIG" --json | \
  python3 -c 'import json,sys; [print(l["topics"][1]) for l in json.load(sys.stdin)]')

REFUNDED=0
for JOB_ID in $JOB_IDS; do
  STATUS=$(cast call "$JOB_ESCROW" "escrowStatus(bytes32)(uint8)" "$JOB_ID" --rpc-url "$RPC_URL")
  [[ "$STATUS" != "$STATUS_LOCKED" ]] && continue

  EXPIRES_AT=$(cast call "$JOB_ESCROW" "escrowExpiresAt(bytes32)(uint64)" "$JOB_ID" --rpc-url "$RPC_URL")
  if (( NOW > EXPIRES_AT )); then
    echo "  refunding expired job $JOB_ID (expired at $EXPIRES_AT)"
    cast send "$JOB_ESCROW" "refundEscrow(bytes32)" "$JOB_ID" \
      --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" >/dev/null
    REFUNDED=$((REFUNDED + 1))
  fi
done

echo "Done. Refunded $REFUNDED expired escrow(s)."

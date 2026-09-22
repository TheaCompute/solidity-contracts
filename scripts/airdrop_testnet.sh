#!/usr/bin/env bash
# airdrop_testnet.sh - Check deployer balance and print Robinhood Chain testnet
# faucet guidance. Gas on Robinhood Chain is ETH; testnet ETH comes from the
# faucet linked in the chain docs (https://docs.robinhood.com/chain/).
#
# Usage:
#   ./scripts/airdrop_testnet.sh [address]
#
# If no address is given, derives it from the DEPLOYER_KEY env var.

set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.testnet.chain.robinhood.com}"

if [[ $# -ge 1 ]]; then
  ADDRESS="$1"
else
  : "${DEPLOYER_KEY:?Pass an address or set DEPLOYER_KEY}"
  ADDRESS=$(cast wallet address --private-key "$DEPLOYER_KEY")
fi

echo "Robinhood Chain testnet (chain ID 46630)"
echo "  address: $ADDRESS"
echo "  rpc:     $RPC_URL"
echo ""

BALANCE_WEI=$(cast balance "$ADDRESS" --rpc-url "$RPC_URL")
echo "Current balance: $(cast from-wei "$BALANCE_WEI") ETH"
echo ""
echo "Need testnet ETH? Use the faucet listed in the chain docs:"
echo "  https://docs.robinhood.com/chain/"
echo "or bridge Sepolia ETH via the testnet bridge, then re-run this script."

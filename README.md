# TheaCompute contracts

The onchain side of [TheaCompute](https://theacompute.com), the open AI inference network on Robinhood Chain. GPU operators stake $THEA to do work, clients pay in USDG, and every job is settled in public. No need to take our word for anything, it's all onchain.

## How it works

1. **Workers stake.** GPU operators register and lock $THEA as collateral.
2. **Clients prepay.** USDG goes into escrow as credits (1 credit = $0.01).
3. **Jobs get claimed.** A job is posted to the onchain job board and a qualified worker picks it up.
4. **Workers get paid.** Once the worker submits proof, they're paid instantly from escrow.
5. **Cheaters get slashed.** If a client disputes and the worker is found dishonest, part of their stake is slashed.

Stakers also vote on protocol changes and earn a share of USDG rewards.

## Live on testnet

Robinhood Chain testnet (chain ID 46630). Browse everything on the [explorer](https://explorer.testnet.chain.robinhood.com).

| Contract | What it does | Address |
|---|---|---|
| WorkerRegistry | List of GPU workers and their reputation | `0xf394B64a4f9eD1b34139B57dA2362C57A22DDA31` |
| Staking | Locks $THEA for 30, 90 or 180 days | `0xf46FaE5eD2B3125d0e5B3DC3FC1D1ADAD01b635A` |
| JobEscrow | Holds client USDG until work is done | `0x413A6C7c2b7e2f08763aB0aac3941351694433Ac` |
| JobRouter | The onchain job board | `0x95eD220738E16AD9e3F4687fa91cD04b6734AC29` |
| Settlement | Pays workers and handles disputes | `0xAc0B5B9754FB3b1a0419D82C06620eb8611fc5c8` |
| Governance | Stake-weighted voting | `0xbCb63Eb23Dd98070F94A47eA0888B629aFcB74D1` |
| RewardDistributor | Pays USDG rewards to stakers | `0x87deeF92e521f0Fc792039187DC2433d8381a75C` |
| ModelRegistry | Which AI models the network runs | `0xc743eDae40D31c7b1691269194bBcfd24b03EF34` |
| MockUSDG | Test USDG, testnet only | `0xF66A07Bf06831B51500184c5D5CE54532346b2cA` |

## For developers

Built with [Foundry](https://getfoundry.sh). Source is in [`src/`](src).

```bash
forge build
forge test
```

To deploy your own copy, run `DEPLOYER_KEY=0x... ./scripts/deploy.sh` with a funded testnet key.

#!/usr/bin/env bash
# Local Robinhood Chain fork with beeef deployed and wired up, for the indexer, keeper and web app.
#   ROBINHOOD_RPC_URL=... pnpm fork          (keeps anvil running in the foreground)
# Writes deployments/local.json. Anvil account #0 deploys; dev wallets #0-#4 get 10,000 USDG each.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ROBINHOOD_RPC_URL:?set ROBINHOOD_RPC_URL (see packages/contracts/.env.example)}"
PORT="${PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
AIRLOCK=0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862
INITIALIZER=0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
USDG_BALANCE_SLOT=1
DEV_WALLETS=(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65)

anvil --fork-url "$ROBINHOOD_RPC_URL" --chain-id 31337 --port "$PORT" --block-time 1 --silent \
  --retries 20 --fork-retry-backoff 3000 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.5; done

(cd packages/contracts && forge script script/DeployLocal.s.sol --rpc-url "$RPC" --private-key "$KEY0" --broadcast --slow >/dev/null)
FACTORY=$(jq -r .factory deployments/local.json)
MIGRATOR=$(jq -r .predictionMigrator deployments/local.json)
HOOK=$(jq -r .clockHook deployments/local.json)

# Module registration on the Airlock (migrator whitelist, hook flags), done here by impersonating the Airlock owner.
OWNER=$(cast call "$AIRLOCK" "owner()(address)" --rpc-url "$RPC")
cast rpc anvil_impersonateAccount "$OWNER" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$AIRLOCK" "setModuleState(address[],uint8[])" "[$MIGRATOR]" "[4]" --from "$OWNER" --unlocked --rpc-url "$RPC" >/dev/null
cast send "$INITIALIZER" "setDopplerHookState(address[],uint256[])" "[$HOOK]" "[3]" --from "$OWNER" --unlocked --rpc-url "$RPC" >/dev/null

# 10,000 USDG per dev wallet (writes the balances mapping directly).
for w in "${DEV_WALLETS[@]}"; do
  slot=$(cast index address "$w" "$USDG_BALANCE_SLOT")
  cast rpc anvil_setStorageAt "$USDG" "$slot" "$(cast to-uint256 10000000000)" --rpc-url "$RPC" >/dev/null
done

echo "beeef local fork ready on $RPC (chain 31337)"
echo "  factory   $FACTORY"
echo "  migrator  $MIGRATOR  (whitelisted)"
echo "  clockHook $HOOK  (registered)"
echo "  USDG      10,000 in each anvil dev wallet"
wait $ANVIL

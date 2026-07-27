#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${USDC_ADDRESS:?USDC_ADDRESS is required}"
: "${VRF_COORDINATOR:?VRF_COORDINATOR is required}"
: "${VRF_SUBSCRIPTION_ID:?VRF_SUBSCRIPTION_ID is required}"
: "${VRF_KEY_HASH:?VRF_KEY_HASH is required}"
: "${VRF_CALLBACK_GAS_LIMIT:?VRF_CALLBACK_GAS_LIMIT is required}"
: "${VRF_REQUEST_CONFIRMATIONS:?VRF_REQUEST_CONFIRMATIONS is required}"
: "${VRF_NATIVE_PAYMENT:?VRF_NATIVE_PAYMENT is required}"

ARGS=(
  "script/Auction.s.sol:AuctionScript"
  "--rpc-url" "$RPC_URL"
  "--private-key" "$PRIVATE_KEY"
  "--broadcast"
)

if [[ "${VERIFY:-false}" == "true" ]]; then
  : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required when VERIFY=true}"
  ARGS+=("--verify" "--etherscan-api-key" "$ETHERSCAN_API_KEY")
fi

forge script "${ARGS[@]}"

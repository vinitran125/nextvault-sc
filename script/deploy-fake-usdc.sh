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

ARGS=(
  "script/FakeUSDC.s.sol:FakeUSDCScript"
  "--rpc-url" "$RPC_URL"
  "--private-key" "$PRIVATE_KEY"
  "--broadcast"
)

if [[ "${VERIFY:-false}" == "true" ]]; then
  : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required when VERIFY=true}"
  ARGS+=("--verify" "--etherscan-api-key" "$ETHERSCAN_API_KEY")
fi

forge script "${ARGS[@]}"

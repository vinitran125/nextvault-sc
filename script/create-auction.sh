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
: "${AUCTION_ADDRESS:?AUCTION_ADDRESS is required}"
: "${LOT_ID:?LOT_ID is required}"
: "${CONSIGNOR_ADDRESS:?CONSIGNOR_ADDRESS is required}"
: "${LOW_ESTIMATE:?LOW_ESTIMATE is required}"
: "${HIGH_ESTIMATE:?HIGH_ESTIMATE is required}"
: "${STARTING_BID:?STARTING_BID is required}"
: "${BID_INCREMENT:?BID_INCREMENT is required}"
: "${PREVIEW_DURATION_SECONDS:?PREVIEW_DURATION_SECONDS is required}"
: "${AUCTION_DURATION_SECONDS:?AUCTION_DURATION_SECONDS is required}"
: "${NFT_MAX_SUPPLY:?NFT_MAX_SUPPLY is required}"
: "${NFT_PRICE_RATIO_BPS:?NFT_PRICE_RATIO_BPS is required}"
: "${NFT_NAME:?NFT_NAME is required}"
: "${NFT_SYMBOL:?NFT_SYMBOL is required}"
: "${METADATA_URI:?METADATA_URI is required}"

forge script "script/CreateAuction.s.sol:CreateAuctionScript" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

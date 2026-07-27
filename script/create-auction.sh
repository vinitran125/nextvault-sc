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
: "${PREVIEW_DURATION_SECONDS:?PREVIEW_DURATION_SECONDS is required}"
: "${AUCTION_DURATION_SECONDS:?AUCTION_DURATION_SECONDS is required}"
: "${VARIANT_1_QUANTITY:?VARIANT_1_QUANTITY is required}"
: "${VARIANT_2_QUANTITY:?VARIANT_2_QUANTITY is required}"
: "${VARIANT_3_QUANTITY:?VARIANT_3_QUANTITY is required}"
: "${NFT_PRICE_RATIO_BPS:?NFT_PRICE_RATIO_BPS is required}"
: "${NFT_NAME:?NFT_NAME is required}"
: "${NFT_SYMBOL:?NFT_SYMBOL is required}"
: "${THUMBNAIL_URL:?THUMBNAIL_URL is required}"
: "${METADATA_URI:?METADATA_URI is required}"

LOT_ID_BYTES32="0x$(printf '%s' "$LOT_ID" | tr -d '-')00000000000000000000000000000000"
export LOT_ID_BYTES32

forge script "script/CreateAuction.s.sol:CreateAuctionScript" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

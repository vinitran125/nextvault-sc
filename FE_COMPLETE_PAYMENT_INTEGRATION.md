# FE integration: complete auction payment on-chain

FE không gọi endpoint `POST /api/v1/auctions/:id/complete-payment` nữa. Winner kết nối ví và gọi trực tiếp:

```solidity
settleAuctionPayment(bytes32 lotId) returns (bool paymentCollected)
```

Hàm chỉ cho phép:

- Ví winner của auction.
- Ví có `OPERATOR_ROLE`.

## Điều kiện hiển thị nút Complete payment

Dùng dữ liệu auction detail từ backend và chỉ hiển thị nút khi:

```ts
auction.status === "ended" &&
auction.paymentCollected === false &&
auction.winnerWalletAddress?.toLowerCase() === connectedAddress?.toLowerCase()
```

Nếu sản phẩm vẫn áp dụng grace period cho winner, FE kiểm tra thêm:

```ts
new Date(auction.paymentGraceDeadline).getTime() > Date.now()
```

## ABI tối thiểu

```ts
export const auctionPaymentAbi = [
  {
    type: "function",
    name: "settleAuctionPayment",
    stateMutability: "nonpayable",
    inputs: [{ name: "lotId", type: "bytes32" }],
    outputs: [{ name: "paymentCollected", type: "bool" }],
  },
  {
    type: "function",
    name: "auctionPaymentCollected",
    stateMutability: "view",
    inputs: [{ name: "", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "buyerPremiumBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint16" }],
  },
  {
    type: "function",
    name: "token",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "event",
    name: "WinnerPaymentCollected",
    anonymous: false,
    inputs: [
      { indexed: true, name: "lotId", type: "bytes32" },
      { indexed: true, name: "winner", type: "address" },
      { indexed: false, name: "winningBid", type: "uint256" },
      { indexed: false, name: "paymentCollected", type: "bool" },
      { indexed: false, name: "blockTimestamp", type: "uint256" },
    ],
  },
] as const

export const erc20PaymentAbi = [
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const
```

## Chuyển `itemId` thành `lotId`

`itemId` từ API là UUID. Contract dùng `bytes32` bằng cách bỏ dấu `-` và pad `0` bên phải đến đủ 64 ký tự hex:

```ts
import type { Hex } from "viem"

export const itemIdToLotId = (itemId: string): Hex =>
  `0x${itemId.replaceAll("-", "").padEnd(64, "0")}` as Hex
```

Không dùng `stringToHex()` hoặc hash UUID vì sẽ tạo ra `lotId` khác.

## Số USDC cần approve

Contract đã giữ deposit bằng 10% hammer price. Số tiền còn lại:

```ts
const BPS_DENOMINATOR = 10_000n
const DEPOSIT_DENOMINATOR = 10n

const buyerPremium =
  (BigInt(auction.hammerPrice) * BigInt(buyerPremiumBps)) /
  BPS_DENOMINATOR

const remainingPayment =
  BigInt(auction.hammerPrice) +
  buyerPremium -
  BigInt(auction.hammerPrice) / DEPOSIT_DENOMINATOR
```

Các giá trị `hammerPrice` và `remainingPayment` dùng raw token units, không gọi `parseUnits()` thêm lần nữa.

## Flow Wagmi/Viem

```ts
import {
  getAddress,
  type Address,
} from "viem"
import {
  readContract,
  waitForTransactionReceipt,
  writeContract,
} from "wagmi/actions"
import { config } from "./wagmi"

export async function completeAuctionPayment(input: {
  auctionAddress: Address
  connectedAddress: Address
  itemId: string
  winnerWalletAddress: string
  hammerPrice: string
}) {
  const {
    auctionAddress,
    connectedAddress,
    itemId,
    winnerWalletAddress,
    hammerPrice,
  } = input

  if (getAddress(connectedAddress) !== getAddress(winnerWalletAddress)) {
    throw new Error("Connected wallet is not the auction winner")
  }

  const lotId = itemIdToLotId(itemId)

  const alreadyCollected = await readContract(config, {
    address: auctionAddress,
    abi: auctionPaymentAbi,
    functionName: "auctionPaymentCollected",
    args: [lotId],
  })

  if (alreadyCollected) return { alreadyCollected: true as const }

  const [tokenAddress, buyerPremiumBps] = await Promise.all([
    readContract(config, {
      address: auctionAddress,
      abi: auctionPaymentAbi,
      functionName: "token",
    }),
    readContract(config, {
      address: auctionAddress,
      abi: auctionPaymentAbi,
      functionName: "buyerPremiumBps",
    }),
  ])

  const hammerPriceValue = BigInt(hammerPrice)
  const buyerPremium =
    (hammerPriceValue * BigInt(buyerPremiumBps)) / 10_000n
  const remainingPayment =
    hammerPriceValue + buyerPremium - hammerPriceValue / 10n

  const allowance = await readContract(config, {
    address: tokenAddress,
    abi: erc20PaymentAbi,
    functionName: "allowance",
    args: [connectedAddress, auctionAddress],
  })

  if (allowance < remainingPayment) {
    const approveHash = await writeContract(config, {
      address: tokenAddress,
      abi: erc20PaymentAbi,
      functionName: "approve",
      args: [auctionAddress, remainingPayment],
    })

    const approveReceipt = await waitForTransactionReceipt(config, {
      hash: approveHash,
    })
    if (approveReceipt.status !== "success") {
      throw new Error("USDC approval failed")
    }
  }

  const settlementHash = await writeContract(config, {
    address: auctionAddress,
    abi: auctionPaymentAbi,
    functionName: "settleAuctionPayment",
    args: [lotId],
  })

  const settlementReceipt = await waitForTransactionReceipt(config, {
    hash: settlementHash,
  })
  if (settlementReceipt.status !== "success") {
    throw new Error("Auction payment transaction reverted")
  }

  // Transaction có thể success nhưng paymentCollected vẫn false nếu winner
  // không đủ balance/allowance tại thời điểm contract thực thi.
  const paymentCollected = await readContract(config, {
    address: auctionAddress,
    abi: auctionPaymentAbi,
    functionName: "auctionPaymentCollected",
    args: [lotId],
  })

  if (!paymentCollected) {
    throw new Error("Payment was not collected; check USDC balance and allowance")
  }

  return {
    alreadyCollected: false as const,
    transactionHash: settlementHash,
  }
}
```

## Trạng thái UI đề xuất

1. `Checking payment`: đọc token, premium, allowance và balance.
2. `Approve USDC`: chỉ xuất hiện nếu allowance chưa đủ.
3. `Confirm payment`: gọi `settleAuctionPayment`.
4. `Waiting for confirmation`: chờ transaction receipt.
5. `Syncing auction`: refetch auction detail cho đến khi
   `paymentCollected === true` hoặc `status === "finalized"`.

Backend cập nhật auction từ event on-chain nên API có thể chậm hơn receipt vài giây.

## Xử lý lỗi

| Contract error | Ý nghĩa/UI |
| --- | --- |
| `UnauthorizedPaymentCollector` | Ví hiện tại không phải winner. Yêu cầu đổi ví. |
| `AuctionNotEnded` | Auction chưa được end on-chain. |
| `AuctionHasNoWinner` | Auction không có winner để thanh toán. |
| `AuctionPaymentAlreadyCollected` | Thanh toán đã hoàn tất; refetch auction và hiển thị finalized. |

Ngoài các lỗi trên:

- Kiểm tra đúng network và đúng địa chỉ Auction proxy.
- Kiểm tra USDC balance phải lớn hơn hoặc bằng `remainingPayment`.
- Nếu operator settlement chạy đồng thời và thắng trước, giao dịch FE có thể revert
  `AuctionPaymentAlreadyCollected`; xử lý như trạng thái thành công sau khi refetch.
- Disable nút trong lúc approve hoặc settlement đang pending để tránh gửi nhiều transaction.

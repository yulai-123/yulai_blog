---
title: DeFi 资产读取与解析：Uniswap V3 协议接入
date: 2026-06-20 23:00:00
updated: 2026-06-20 23:00:00
categories:
- DeFi
tags:
- DeFi
- Go
- EVM
- Uniswap
- AMM
- 链上资产
description: 介绍 Uniswap V3 的 LP NFT、Tick 区间、集中流动性和未领取手续费如何映射到 defi-position-reader 的 metadata sync 与 Position fetch 链路。
---

这篇是 `defi-position-reader` 系列的第五篇，继续围绕 DEX / AMM 协议展开，记录 Uniswap V3 的 Liquidity Pool NFT 仓位如何读取。项目代码放在 [yulai-123/defi-position-reader](https://github.com/yulai-123/defi-position-reader)。

<!-- more -->

## 背景

上一期接入了 Uniswap V2，这一期继续接入 Uniswap V3。两者都属于 DEX / AMM 协议，但 V3 是目前更常见、也更复杂的流动性池形态之一。

和 Uniswap V2 不同，Uniswap V3 的 LP 仓位不再用普通 LP Token 表示，而是用 NFT 表示。每个 NFT 对应一笔独立的流动性仓位，并带有自己的价格区间和手续费记录。

这篇文章会围绕 Uniswap V3 的 Liquidity Pool 仓位，说明项目中如何读取用户持有的 LP NFT，并把它解析成统一的 `Position`。

## 目标

1. 理清 Uniswap V3 LP NFT、Pool、价格区间和手续费之间的关系。
2. 说明接入 Uniswap V3 时，哪些数据需要先同步，哪些数据需要在查询用户资产时实时读取。
3. 完成 Liquidity Pool 仓位解析，把用户本金和未领取手续费展示出来。

## 过程

### 协议介绍

Uniswap V3 和 Uniswap V2 一样，都是 DEX / AMM 协议。用户可以向交易池提供两种代币，成为流动性提供者，并从交易手续费中获得收益。

两者最大的区别在于流动性仓位的表达方式。Uniswap V2 使用 ERC20 LP Token 表示用户在整个池子里的份额；Uniswap V3 则使用 NFT 表示每一笔独立的 LP 仓位。

V3 的 LP NFT 会记录这笔仓位对应的 pool、价格区间、liquidity 和手续费信息。用户添加流动性时，可以选择只在某个价格区间内提供资金。只有当市场价格落在这个区间内时，这笔资金才会参与做市并赚取手续费。

这种设计提高了资金使用效率，但也让资产解析更复杂。V2 中用户资产基本可以按 LP 份额分摊池子资产；V3 中则需要先读取用户持有的 LP NFT，再结合当前价格和 NFT 的价格区间，计算它当前对应的 token0/token1 数量和未领取手续费。

从资产读取角度看，Uniswap V3 主要关注三个对象：

| 对象 | 作用 |
| --- | --- |
| Pool | 保存两种代币和当前交易状态的流动性池 |
| Position NFT | 表示用户的一笔独立 LP 仓位 |
| Tick 区间 | 表示这笔仓位在哪个价格范围内提供流动性 |

把这些关系放到项目视角，可以简化成下面这张图。

![Uniswap V3 资产模型图](/images/defi-position-reader/uniswap-v3-asset-model.png)

_图 1：Uniswap V3 中用户钱包、LP NFT、Pool、Tick 区间和最终 Position 输出之间的关系。_

### 接入方案

Uniswap V3 当前只接入 Liquidity Pool。Swap 是交易行为，不形成持续持仓；外部 farm 或激励暂不处理。

项目中把一个 Uniswap V3 LP NFT 解析成一个 `liquidity` 类型的 `Position`：

| 字段 | 含义 |
| --- | --- |
| `SHARES` | 用户持有的 LP NFT，用 `UNI-V3-POS` 表示 |
| `UNDERLYING` | 这笔 NFT 当前对应的 token0/token1 本金 |
| `REWARDS` | 这笔 NFT 当前未领取的 swap fee |
| `DEBT` | 不涉及 |

#### Metadata 维护哪些数据

Uniswap V3 的 metadata 主要分成两类：

| Namespace | 作用 |
| --- | --- |
| `markets` | 保存每条链的 Factory、NonfungiblePositionManager、起始区块等入口配置 |
| `pools` | 保存 pool 地址、token0、token1、fee tier、tick spacing 等信息 |

默认情况下，`sync-metadata` 会从 Factory 的 `PoolCreated` 日志发现 pools。这样可以覆盖冷门池子，适合作为完整缓存。

为了 demo 和测试，也可以传入用户地址：

```bash
go run ./cmd/dpr sync-metadata \
  -chain base \
  -protocol uniswap-v3 \
  -address 0x...
```

这种模式只同步该地址当前持有的 LP NFT 关联 pools，速度更快，但只适合当前地址。

#### Fetcher 如何读取用户仓位

查询用户资产时，Fetcher 会从 NonfungiblePositionManager 枚举用户持有的 LP NFT，再回到对应 pool 读取实时状态。

![Uniswap V3 Position 读取流程图](/images/defi-position-reader/uniswap-v3-position-flow.png)

_图 2：Fetcher 如何依赖 metadata 读取 LP NFT、pool runtime state，并生成统一的 Position。_

这里和 Uniswap V2 最大的区别是：V2 只需要按 LP Token 份额分摊整个池子，而 V3 必须逐个 NFT 计算，因为每个 NFT 都有自己的价格区间。

#### 代码结构

Uniswap V3 的代码集中在 `protocols/uniswapv3`：

| 文件 | 作用 |
| --- | --- |
| `config.go` | 配置各链 Factory、PositionManager、起始区块等链配置 |
| `types.go` | 定义 `Market`、`Pool` 等 metadata 结构 |
| `syncer.go` | 同步 markets 和 pools，支持全量同步和用户地址模式 |
| `fetcher.go` | 读取用户 LP NFT，并生成 `Position` |
| `math.go` | 处理 tick、liquidity、本金和手续费计算 |
| `abi.go` | 合约 ABI、参数打包和返回值解析 |
| `adapter.go` | 协议注册入口 |

### 用户资产如何计算

Uniswap V3 的计算主要分成两部分：本金和未领取手续费。

本金计算依赖 NFT 里的 `liquidity`、价格区间和 pool 当前价格。每个 LP NFT 都会记录自己的 `tickLower` 和 `tickUpper`，pool 的 `slot0` 会返回当前价格和当前 tick。

根据当前价格和 NFT 区间的关系，仓位会有三种状态：

| 状态 | 含义 | 本金表现 |
| --- | --- | --- |
| below-range | 当前价格低于区间 | 主要表现为 token0 |
| in-range | 当前价格在区间内 | 同时包含 token0 和 token1 |
| above-range | 当前价格高于区间 | 主要表现为 token1 |

项目会把 tick 转成对应的 `sqrtPriceX96`，再用 Uniswap V3 的 liquidity 计算方式，把 `liquidity` 还原成当前对应的 token0/token1 数量。最终这些结果会展示在 `UNDERLYING` 中。

未领取手续费的计算依赖 fee growth。Pool 会记录全局手续费增长，tick 上也会记录区间外的手续费增长。对于某个 NFT 仓位，需要先算出它所在区间内部的 fee growth，再和 NFT 上次记录的 fee growth 做差，最后乘以这笔仓位的 liquidity。

简单理解就是：未领取手续费 = 已记录但未领取的 `tokensOwed` + 本次区间内新增手续费。

项目会把这部分结果展示在 `REWARDS` 中。

这里需要注意一点：Uniswap V3 的本金会随着当前价格变化而变化，价格区间越窄，token0/token1 的数量变化越明显。

### 运行 Case

下面用 Base 上的地址做示例。这个地址持有 Uniswap V3 LP NFT，可以用来验证 metadata 同步、NFT 枚举、本金和手续费解析。示例地址的链上状态可能会随着用户操作变化，运行时以当前链上结果为准。

```bash
OWNER=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045

go run ./cmd/dpr sync-metadata \
  -chain base \
  -protocol uniswap-v3 \
  -address $OWNER \
  -format detail \
  -trace

go run ./cmd/dpr positions \
  -chain base \
  -protocol uniswap-v3 \
  -address $OWNER \
  -format table \
  -trace
```

运行结果里重点看三部分：

1. `sync-metadata` 是否发现了该地址相关的 pools。
2. `positions` 是否输出 `liquidity` 类型仓位。
3. `UNDERLYING` 是否展示本金，`REWARDS` 是否展示未领取手续费。

## 结论

这次接入完成了 Uniswap V3 Liquidity Pool 仓位的读取与解析。项目可以通过用户地址找到其持有的 LP NFT，并把每个 NFT 当前对应的本金和未领取手续费计算出来。

和 Uniswap V2 相比，Uniswap V3 的主要差异在于每个 LP NFT 都有自己的价格区间，因此不能再按统一的 LP Token 份额分摊池子资产，而是需要逐个 NFT 进行计算。

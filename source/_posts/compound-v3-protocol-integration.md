---
title: DeFi 资产读取与解析：Compound V3 协议接入
date: 2026-06-14 23:20:00
updated: 2026-06-14 23:20:00
categories:
- DeFi
tags:
- DeFi
- Go
- EVM
- Compound
- 链上资产
description: 介绍 Compound V3 的 Comet、base asset、collateral asset 和 reward 如何映射到 defi-position-reader 的 metadata sync 与 Position fetch 链路。
---

这篇是 `defi-position-reader` 系列的第三篇，继续从 Aave V3 走向另一个借贷协议：Compound V3。项目代码放在 [yulai-123/defi-position-reader](https://github.com/yulai-123/defi-position-reader)。

<!-- more -->

## 背景

在上一篇文章中，我们接入了 Aave V3，并用它展示了一个典型借贷协议的资产读取方式：先同步 Market、Reserve、aToken、debt token 等公共数据，再按用户地址读取供应、债务和风险指标，最后映射成统一的 `Position`。

这一篇继续接入另一个经典借贷协议：Compound V3，也就是 Compound III / Comet。

Compound V3 和 Aave V3 都是借贷协议，但它们的资产组织方式不太一样。Aave V3 的一个 Market 中可以有多个 Reserve，每个资产都有自己的供应和借贷配置；Compound V3 则把一个市场收敛成一个 Comet，每个 Comet 只有一个 base asset，其他资产只能作为 collateral asset。

这个差异让 Compound V3 很适合作为 Aave V3 之后的第二个真实借贷协议案例。它的协议模型更集中，但仍然覆盖借贷仓位读取中常见的几个问题：市场 metadata 如何维护，用户供应和债务如何读取，抵押资产如何解析，以及结果如何和 DeBank 的池子口径对齐。

## 目标

围绕 Compound V3 的资产读取与解析，本文主要关注三件事。

1. 理解 Compound V3 的基本结构：一个 Comet 市场、一个 base asset，以及多个 collateral asset。
2. 说明 Compound V3 如何映射到项目中的 `MetadataSyncer` 和 `Fetcher`。
3. 通过真实链上地址运行 CLI，验证解析结果是否能和 DeBank 的池子口径对齐。

## 过程

### Compound V3 的 Comet 资产模型

Compound 是 DeFi 生态里较早出现的借贷协议之一。早期的 Compound V2 使用 cToken 市场模型，每个资产都有自己的 cToken；Compound V3，也就是 Compound III / Comet，则把市场收敛到 Comet。

一个 Comet 只有一个 base asset，用户可以供应或借入这个 base asset。其他资产只作为 collateral asset，用来增加用户的借款能力。把这层关系放到资产读取视角下，可以简化成下面这张图：

![Compound V3 Comet 资产模型图](/images/defi-position-reader/compound-v3-comet-model.svg)

和 Aave V3 相比，Compound V3 的取舍更清晰。Aave V3 的多 Reserve 模型更灵活，用户可以在同一个 Market 中供应、抵押和借入多种资产，资产覆盖面和策略空间更大；但代价是风险组合也更复杂，每新增一个 Reserve，都需要额外考虑预言机、流动性、清算和债务侧风险。

Compound V3 的 Comet 模型更集中。一个 Comet 只允许借入一种 base asset，其他资产只能作为 collateral asset。这样做的好处是风险边界更清楚，协议可以围绕单一 base asset 来设计利率、流动性和清算参数；代价是灵活性更弱，如果要支持多个借入资产，就需要多个 Comet，collateral asset 本身也不会产生供应利息。

### 接入方案

理解 Comet 的资产模型后，Compound V3 的接入可以围绕两个问题展开：一个 Comet 需要同步哪些公共数据，以及用户在这个 Comet 中会形成哪些仓位。

项目中把同一个 Comet 拆成两类结果：`yield` 表示用户供应 base asset 获得利息；`lending` 表示用户提供 collateral asset，并可能借入 base asset。二者不会合成一个 Position，因为它们的资产含义和风险字段不同。

如果用户存在可领取奖励，项目会额外生成一个 `reward` position。它只展示 reward token，不参与 Yield 或 Lending 的本金、债务和风险计算。

#### MetadataSyncer 需要维护哪些数据

Compound V3 当前维护三类 metadata namespace。

| Namespace | 作用 |
| --- | --- |
| `markets` | 保存 Comet market、base asset、base price feed、base scale、Comet token 等信息 |
| `collateral-assets` | 保存每个 Comet 支持的 collateral asset、price feed、scale、collateral factor、liquidation factor 和 supply cap |
| `reward-configs` | 保存 rewards contract、reward token 和 reward config，用于后续读取可领取奖励 |

这三类 metadata 分别确定 Comet 市场边界、collateral 资产边界，以及后续读取奖励所需的合约信息。

#### Fetcher 如何读取用户仓位

Fetcher 会先校验这三类 metadata，缺失或过期时提示先运行 `sync-metadata`。随后它会对每个 Comet 批量调用下表方法，最终生成 `yield`、`lending` 和可选的 `reward` position。

| 数据 | 方法 | 用途 |
| --- | --- | --- |
| base asset supply | `balanceOf(owner)` | 判断是否生成 Yield 仓位 |
| base asset debt | `borrowBalanceOf(owner)` | 生成 Lending 仓位中的 `Debt` |
| collateral balance | `collateralBalanceOf(owner, asset)` | 生成 Lending 仓位中的抵押资产 |
| borrow status | `isBorrowCollateralized(owner)` | 判断账户是否满足抵押要求 |
| liquidation status | `isLiquidatable(owner)` | 判断账户是否可被清算 |
| price | `getPrice(priceFeed)` | 计算风险字段 |
| rewards | `getRewardOwed(comet, owner)` | 读取可领取奖励 |

#### 用户资产如何计算

![Compound V3 Position 计算链路](/images/defi-position-reader/compound-v3-position-calculation.svg)

Yield 仓位比较直接：

```text
shares = Comet.balanceOf(owner)
underlying = shares
```

这里的 Comet token 本身就是 base asset 的计息凭证，所以用户持有的 share 和当前可视作的 base asset supply 数量是一一对应的。

Lending 仓位由 collateral 和 base asset debt 组成：

```text
collateral = collateralBalanceOf(owner, asset)
debt = borrowBalanceOf(owner)
```

如果某个 collateral balance 为 0，就不会放进结果；如果所有 collateral 和 debt 都为 0，就不会生成 Lending Position。

风险字段基于 Compound V3 自己的 price feed 和 collateral factor 计算：

```text
collateralValue = collateralBalance * price / scale
borrowCapacity = collateralValue * borrowCollateralFactor / 1e18
liquidationCapacity = collateralValue * liquidateCollateralFactor / 1e18
liquidationHealth = liquidationCapacity / baseDebtValue
```

这些字段主要用于展示用户在当前 Comet 中的借贷风险，不作为价格估值口径。

如果 `getRewardOwed(comet, owner)` 返回非 0，Fetcher 会额外生成一个 `reward` position，只展示可领取的 reward token，不参与上述本金、债务和风险计算。

### 当前支持范围

当前 Compound V3 adapter 的支持范围如下：

| 项目 | 当前状态 |
| --- | --- |
| Protocol ID | `compound-v3` |
| Chains | Ethereum、Arbitrum One、Base |
| Yield | 已支持 base asset supply |
| Lending | 已支持 collateral、base asset debt 和风险字段 |
| Reward | 作为额外 position 补充展示 |
| Metadata | `markets`、`collateral-assets`、`reward-configs` |
| 链上读取 | RPC Client + Multicall3 |

代码结构上，Compound V3 的核心文件集中在 `protocols/compoundv3`：

| 文件 | 作用 |
| --- | --- |
| `config.go` | Comet 市场配置 |
| `types.go` | `Market`、`CollateralAsset`、`RewardConfig` 等 metadata 类型 |
| `syncer.go` | `sync-metadata` 逻辑 |
| `fetcher.go` | 用户仓位读取逻辑 |
| `abi.go` | 合约 ABI 与参数编解码 |

这几个文件共同完成了协议接入的闭环：定义 Comet 市场边界，同步公共数据，读取用户状态，再映射成统一 Position。

### 运行 Case

为了看到完整效果，可以先选择一条链同步 Compound V3 metadata，再查询某个地址的仓位。下面以 Base 上的 USDC Comet 为例，地址可以替换成任意 EVM 地址：

```bash
go run ./cmd/dpr sync-metadata \
  -chain base \
  -protocol compound-v3 \
  -format detail \
  -trace

go run ./cmd/dpr explain \
  -chain base \
  -protocol compound-v3 \
  -format detail

go run ./cmd/dpr positions \
  -chain base \
  -protocol compound-v3 \
  -address 0x14e94b74b8488328a640825294d8275c0ae1dcb3 \
  -format table \
  -trace
```

运行时重点看三件事：`sync-metadata` 是否写入 `markets`、`collateral-assets` 和 `reward-configs`，`explain` 中 metadata cache 是否命中且未过期，`positions` 是否展示 `SUPPLY/SHARES`、`UNDERLYING`、`DEBT` 和 `HEALTH`。

从资产穿透角度看，Lending 行里的 `SUPPLY/SHARES` 来自 `collateralBalanceOf(owner, asset)`，表示用户在这个 Comet 中提供的抵押资产；`DEBT` 来自 `borrowBalanceOf(owner)`，表示用户借入的 base asset。Yield 行里的 `SUPPLY/SHARES` 是 Comet token 余额，`UNDERLYING` 是它对应的 base asset supply。这样 CLI 输出里可以直接看到凭证资产、底层资产和债务之间的关系。

如果该地址存在可领取奖励，CLI 会额外展示一个 `reward` position。它只是补充展示 reward token，不影响 Yield / Lending 的本金和债务结果。

如果需要排查某个资产为什么没有展示，可以把 `positions` 切换成 detail 模式：

```bash
go run ./cmd/dpr positions \
  -chain base \
  -protocol compound-v3 \
  -address 0x14e94b74b8488328a640825294d8275c0ae1dcb3 \
  -format detail \
  -trace \
  -trace-level calls
```

这会展示更完整的 Position 内容，包括 Comet、collateral 明细、price feed、风险字段和 trace 事件。如果示例地址的链上资产发生变化，可以替换成 DeBank holders 页面或 live test fixture 中记录的 Compound V3 持仓地址。

## 结论

Compound V3 的接入重点，是先理解它以 Comet 为中心的资产模型。和 Aave V3 的多 Reserve 结构不同，一个 Comet 只围绕一个 base asset 展开：用户可以供应或借入这个 base asset，其他资产则作为 collateral asset 参与借款能力和清算风险计算。

映射到项目架构后，`MetadataSyncer` 负责维护 Comet market、collateral asset 和 reward config 这些公共数据；`Fetcher` 则按用户地址读取 base asset supply、base asset debt、collateral balance 和风险状态，并最终拆成统一的 `Position`。其中 Yield 体现 base asset 的供应余额，Lending 体现抵押资产、债务和风险字段，reward 只作为额外结果补充展示。

这次接入也延续了前面 Aave V3 的方法：先找到协议如何组织市场和用户资产，再区分公共 metadata 与用户实时状态，最后把链上读取结果穿透成 `Shares`、`Underlying`、`Debt` 和协议扩展字段。后续接入其他借贷协议时，也可以沿着这条路径展开。

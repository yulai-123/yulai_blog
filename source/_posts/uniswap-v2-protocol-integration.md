---
title: DeFi 资产读取与解析：Uniswap V2 协议接入
date: 2026-06-14 23:30:00
updated: 2026-06-14 23:30:00
categories:
- DeFi
tags:
- DeFi
- Go
- EVM
- Uniswap
- AMM
- 链上资产
description: 介绍 Uniswap V2 的 Pair、LP Token、Farming 和奖励如何映射到 defi-position-reader 的 metadata sync 与 Position fetch 链路。
---

这篇是 `defi-position-reader` 系列的第四篇，从借贷协议转到 DEX / AMM，记录 Uniswap V2 的 liquidity pool 和 farming 仓位如何读取。项目代码放在 [yulai-123/defi-position-reader](https://github.com/yulai-123/defi-position-reader)。

<!-- more -->

## 背景

前两篇文章主要围绕借贷协议展开，从 Aave V3 到 Compound V3，可以看到同一类协议在资产组织方式上的差异。接下来把视角转到 DEX / AMM。

和借贷协议不同，Uniswap V2 不记录用户的供应和债务，而是通过流动性池和 LP Token 表达用户份额。这篇文章会围绕 liquidity pool 和 farming 两类资产展开，说明项目中如何把这些份额解析成统一的 `Position`。

## 目标

1. 理清 Uniswap V2 的几个核心对象：Pair、LP Token、池子储备量、手续费，以及 Farming 里质押 LP 和奖励的关系。
2. 说明哪些池子和代币信息适合先同步到 metadata，查询用户资产时再读取哪些实时状态。
3. 完成 liquidity pool 和 farming 两类仓位解析，把 LP 份额还原成对应的 token0/token1，并把可领取奖励单独展示出来。

## 过程

### Uniswap V2 的资产模型

Uniswap V2 可以先按三个合约理解：Factory 负责创建和查询 Pair，Router 是用户交易、添加流动性和移除流动性的入口，Pair 则是真正持有两种 token 的流动性池。对资产读取来说，最核心的对象是 Pair。

每个 Pair 对应一个交易对，例如 WETH/USDC。用户向 Pair 同时存入两种 token 后，会拿到这个 Pair 铸造的 LP Token。LP Token 代表用户在池子里的份额，而不是某一种单独资产；读取用户资产时，需要把这份 LP 份额还原成 Pair 中对应的 token0 和 token1。

把这些关系放到资产读取视角，可以简化成下面这张图。

![Uniswap V2 资产模型图](/images/defi-position-reader/uniswap-v2-asset-model.png)

_图 1：Uniswap V2 中 Pair、LP Token、用户钱包和 Farming 合约之间的资产关系。_

从资产读取角度看，swap 本身更像一次交易行为，不会形成需要持续解析的协议资产；后面真正要处理的是 liquidity pool 和 farming 两类仓位。

> 补充一点 AMM 和价格机制：DEX 是去中心化交易所，AMM 则是其中一种自动做市方式。Uniswap V2 不依赖订单簿撮合，而是用流动性池完成兑换。它的价格由恒定乘积公式 `x * y = k` 决定，其中 `x` 和 `y` 分别是池子中 token0 和 token1 的储备量。交易会改变两边储备量，交易规模越大，对池子比例影响越明显，滑点也越大。

Uniswap V2 的交易手续费会留在池子里，使 LP Token 对应的底层资产随交易累积发生变化。协议也预留了 protocol fee 机制；如果 `feeTo` 被开启，一部分增长会通过额外铸造 LP 的方式分配给协议方。这里先知道它会影响 LP 份额计算即可，具体公式放到后面的资产计算部分再展开。

### 接入方案

Uniswap V2 的接入仍然沿用项目里的两段式：`MetadataSyncer` 维护协议公共数据，`Fetcher` 按用户地址读取实时状态。和借贷协议不同，这里没有债务、抵押率或健康因子，核心问题更集中：找到用户的 LP 份额，再把这份份额换算成 Pair 中的 token0/token1。

完整读取链路可以概括成下面这张图。

![Uniswap V2 Position 计算链路](/images/defi-position-reader/uniswap-v2-position-calculation.png)

_图 2：Fetcher 如何依赖 metadata 读取 direct LP、Farming 和 Pair runtime state，并生成三类 Position。_

#### 仓位类型

项目中把 Uniswap V2 拆成三类 Position。

| 类型 | 含义 |
| --- | --- |
| `liquidity` | 用户钱包里直接持有 LP Token |
| `farming` | 用户把 LP Token 质押在奖励合约中 |
| `reward` | Farming 中已经产生、但还没有领取的奖励 |

`liquidity` 和 `farming` 的底层都是 LP 份额，只是 LP Token 所在的位置不同。计算底层资产时，两者都会回到同一个 Pair 状态上；`reward` 则单独展示，不参与 LP 份额换算。

#### MetadataSyncer 需要维护哪些数据

Uniswap V2 当前维护三类 metadata namespace。

| Namespace | 作用 |
| --- | --- |
| `markets` | 保存当前链上的 Factory、Router、起始区块等市场入口信息 |
| `pairs` | 保存 Pair 地址、token0、token1、LP Token 信息 |
| `farming-pools` | 保存 Farming 合约、对应 Pair、奖励 token 等信息 |

其中 `pairs` 是最核心的数据。默认情况下，项目会从 Factory 读取完整 Pair 列表，避免因为只维护常用池而漏掉冷门 LP。测试或 demo 场景下，也可以在 `sync-metadata` 时传入用户地址，只发现这个地址相关的 Pair；这时 Syncer 会根据用户 ERC20 转账记录找候选合约，再用 `token0`、`token1` 和 `Factory.getPair(token0, token1)` 做校验。

#### Fetcher 如何读取用户仓位

Fetcher 会先检查这三类 metadata 是否存在。随后它会分别读取 direct LP、Farming 和 Pair 当前状态。

| 仓位 | 方法 | 用途 |
| --- | --- | --- |
| direct LP | `Pair.balanceOf(owner)` | 判断用户是否直接持有 LP Token |
| farming LP | `StakingRewards.balanceOf(owner)` | 判断用户质押了多少 LP Token |
| farming reward | `StakingRewards.earned(owner)` | 读取用户当前可领取奖励 |
| pair state | `getReserves`、`totalSupply`、`kLast`、`feeTo`、`token.balanceOf(pair)` | 计算 LP 份额对应的底层资产 |

Farming 需要单独读取的原因也在这里：用户钱包里的 LP Token 余额可能是 0，但 staking contract 里仍然记录着用户的 LP 份额。

#### 用户资产如何计算

拿到用户 LP 份额后，底层资产按 Pair 当前状态分摊。direct LP 使用用户钱包里的 LP 余额，Farming 使用用户在 staking contract 中的质押余额。

```text
effectiveTotalSupply = totalSupply + protocolLiquidity
amount0 = token0BalanceOfPair * userLpBalance / effectiveTotalSupply
amount1 = token1BalanceOfPair * userLpBalance / effectiveTotalSupply
```

这里使用的是 token 在 Pair 合约上的实际余额，而不是只依赖 `getReserves` 返回的储备量。`effectiveTotalSupply` 则是在 LP 总供应量基础上，额外考虑 protocol fee 可能铸造出来的 LP。大多数情况下这部分为 0；只有 `feeTo` 开启并且 `kLast` 有效时，才需要按 Uniswap V2 的 fee 逻辑修正。

#### 当前支持范围

当前 Uniswap V2 adapter 的支持范围如下：

| 项目 | 当前状态 |
| --- | --- |
| Protocol ID | `uniswap-v2` |
| Chains | Ethereum、Arbitrum One、Base |
| Liquidity Pool | 已支持用户直接持有 LP Token 的仓位 |
| Farming | 已支持 Ethereum legacy UNI rewards pools |
| Reward | 作为额外 position 补充展示 |
| Airdrop | 不接入 |
| Metadata | `markets`、`pairs`、`farming-pools` |
| 链上读取 | RPC Client + Multicall3 |

代码结构上，Uniswap V2 的核心文件集中在 `protocols/uniswapv2`：

| 文件 | 作用 |
| --- | --- |
| `config.go` | Factory、Router 和 Farming pool 配置 |
| `types.go` | `Market`、`Pair`、`FarmingPool` 等 metadata 类型 |
| `syncer.go` | `sync-metadata` 逻辑，包括 full sync 和用户地址模式 |
| `fetcher.go` | 用户 LP、Farming 和奖励读取逻辑 |
| `abi.go` | Factory、Pair、ERC20、StakingRewards ABI 与参数编解码 |
| `adapter.go` | 协议描述和 Adapter 入口 |

这几个文件共同完成了 Uniswap V2 的接入闭环：定义市场和池子边界，同步 Pair 与 Farming metadata，读取用户 LP 份额，再换算成统一 Position。

### 运行 Case

Uniswap V2 的 Pair 数量比较多，默认 `sync-metadata` 会从 Factory 全量同步 Pair，这是最完整的业务口径。为了让博客 demo 更轻量，下面使用 `sync-metadata -address` 只同步示例地址相关的 Pair 和 Farming 配置。这个缓存只适合当前示例地址；如果要查询另一个地址，需要重新用那个地址同步，或者运行默认全量同步。

```bash
OWNER=0xe19537029b8013dc37c55d509b0a5038c7c5ce58

go run ./cmd/dpr sync-metadata \
  -chain ethereum \
  -protocol uniswap-v2 \
  -address $OWNER \
  -format detail \
  -trace

go run ./cmd/dpr positions \
  -chain ethereum \
  -protocol uniswap-v2 \
  -address $OWNER \
  -format table \
  -trace
```

运行时重点看两点：`sync-metadata` 的 discovery 是否显示 `mode=user`，以及 `positions` 是否展示 `liquidity` 仓位。表格中的 `SUPPLY/SHARES` 是用户持有的 LP Token 数量，`UNDERLYING` 则是这份 LP 当前对应的 token0/token1。

如果想看 Farming，可以把 `OWNER` 换成有质押 LP 的地址，例如 `0x99e71af1d19bc3f1e67d67696354c0df218441bc`，再重新执行上面两条命令。Farming 结果里，`farming` position 表示用户质押在 staking contract 中的 LP 份额；如果存在可领取奖励，还会额外出现一个 `reward` position。排查时可以把 `positions` 切到 `-format detail -trace-level calls`，查看 Pair、Farming pool 和公式相关字段。

## 结论

Uniswap V2 的接入重点，是理解 LP Token 背后的资产关系。用户表面上持有的是某个 Pair 的 LP Token，但真正需要展示的是这份 LP 当前对应的 token0 和 token1；如果 LP Token 被质押到 Farming 合约中，还要额外读取 staking contract 中的份额和奖励。

映射到项目架构后，`MetadataSyncer` 负责维护 Market、Pair 和 Farming pool 这些公共数据；`Fetcher` 则按用户地址读取 LP 份额、pending reward 和 Pair 当前状态，并转换成统一的 `Position`。

这次接入和前面的借贷协议不太一样：Aave V3、Compound V3 主要围绕供应、债务和抵押展开，Uniswap V2 则围绕流动性份额展开。但整体方法是一致的，都是先找到协议如何记录用户份额，再区分公共 metadata 和用户实时状态，最后把链上数据还原成更容易理解的底层资产。

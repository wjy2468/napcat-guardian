# 实验 Runbook：`o3HookMode` 1 → 0

> 目的：验证「关闭 hook 模式能不能让登录会话活得更久」。
> 成本：一次重启 + 一次扫码（约 2 分钟）。观察期：24–48 小时。
> 结论判据：会话寿命中位数，不是"还掉不掉线"。

## 为什么值得做这一个实验

社区诊断（[napcat-offline-diagnosis](https://github.com/TomoyoNatsume/dsh-qq-bridge/blob/main/docs/napcat-offline-diagnosis.md)）里唯一被明确建议、且成本可控的操作就是它。
其余建议（提高保活频率、循环重启、删 QQ 数据、频繁换 IP）都是**加重**而不是缓解：反复重连本身就会被判异常。

我这边现有的证据（见 [`掉线取证.md`](掉线取证.md)）：

- 14 次被踢的会话时长中位 **116.5 分钟**，10/14 落在 109–137 分钟；
- 同时有 4 次会话活过 2 小时**没有**被踢，而是死在 `1006514 网络连接异常!` 上。

所以真正的问题是「票据续期失败」和「长连接死掉」这两件事谁占主导，`o3HookMode` 恰好影响前者。

## 前置条件

| 项 | 要求 |
|---|---|
| 基线快照 | `D:\napcat\kick-baseline-20261115.json`（14 次，median 116.5） |
| 机器人状态 | 在线（离线时做也行，反正都要扫码，但别在熔断期改） |
| 当前配置 | 先跑一次 `.\scripts\research\set-o3hookmode.ps1 -Mode 0` 预演，确认改的是哪几个文件 |
| 时间点 | 建议在**下次被踢、你本来就要扫码**的时候做——这样实验的启动成本是 0 |

## 步骤

```powershell
# 0) 确认基线还在
Get-Content D:\napcat\kick-baseline-20261115.json -Raw | ConvertFrom-Json | Select-Object count, median

# 1) 只改这一个键（三个 napcat*.json 里有该字段的都会被改）
.\scripts\research\set-o3hookmode.ps1 -Mode 0 -Apply

# 2) 重启 NapCat（会掉线一次）
#    在机器人已经离线、正等扫码的时候做，反而不算额外损失
New-Item -ItemType File -Path D:\napcat\force-relaunch.flag -Force

# 3) 扫码登录（网页扫码页 or 邮件里的二维码附件）

# 4) 登录成功后确认新配置真的生效
.\scripts\ops\status.ps1
```

## 观察期怎么记

- 什么**都不用做**，`guardian.ps1` 会自己维护 `session-since.txt` 和 `metrics.json`；
- 想随时看："这次登录活了多久" → `.\scripts\ops\status.ps1`；
- 24–48 小时后取第二份快照并对比：

```powershell
.\scripts\research\kick-report.ps1 -Json | Set-Content D:\napcat\after-o3hook.json -Encoding UTF8
.\scripts\research\experiment-compare.ps1 -Before D:\napcat\kick-baseline-20261115.json -After D:\napcat\after-o3hook.json
```

判据（`experiment-compare.ps1` 内置）：

| 输出 | 含义 | 动作 |
|---|---|---|
| `improved` | 中位数 ≥15 分钟且 ≥15% 变长 | 保留 `o3HookMode=0`，更新 README 基线 |
| `worse` | 反向超过阈值 | `.\scripts\research\set-o3hookmode.ps1 -Mode 1 -Apply` 改回 |
| `no clear change` | 在噪声内 | 改回默认，别叠加变量 |
| `样本不足` | 两侧各 <4 次被踢 | 继续观察，最多等到 7 天 |

## 回滚

```powershell
.\scripts\research\set-o3hookmode.ps1 -Mode 1 -Apply
# 然后同样用 force-relaunch.flag 重启一次
```

备份文件是 `config\napcat*.json.bak-o3hook-<时间戳>`，出问题可以直接覆盖回去。

## 这个实验回答不了什么

- 它不会让"掉线"消失——只是可能让会话活得更久；
- 它不改变"假在线"（`1006514`）那一类，那条链路由发送失败探测 + 重启覆盖；
- 如果 48 小时后仍是 `no clear change`，说明在这个账号/网络环境下这条路走不通，正确的结论是**接受定期扫码运维**，而不是继续加变量。

## 这个开关在代码里到底做了什么

`NapCat 4.18.42`（`napcat.mjs`，3,344,922 B）里 `o3HookMode` 只出现两处：

- `35427` 行：配置 schema `o3HookMode: l.Number({ default: 0 })` —— **默认值是 0**，我们机器上是 1（安装时被改过或由 UI 写入）。
- `87768` 行：`await n.init(r.getFullQQVersion(), s.o3HookMode === 1);` —— 它只是把 `true/false` 传给 `NativePacketClient.init()`。

再往下看 `fke.init()`（`87171` 行起）：

```js
const a = this.MoeHooExport.exports.initHook?.(i, o, (c, u, d, p, f) => {
  this.emitPacket(c, u, d, p, f);
}, r);
return a !== "success" ? (...) : (this.logger.log("[PacketHandler] 初始化成功"), !0);
```

也就是说：

1. 不论 `o3HookMode` 是 0 还是 1，`initHook` 都会被调用，**包 hook 本身不会被关掉**——这印证了社区文档里那句"`o3HookMode=0` 不等于完全关闭包拦截"。
2. 差别只在传给 native 的第四个参数（`r`）。该参数的含义在 `MoeHoo.win32.x64.node` 里，JS 侧无法进一步确认；从命名和默认值看，它是 hook 的"模式选择"而不是"开关"。
3. 因为默认就是 0，切回 0 相当于回到发行版默认行为，风险主要是"某个依赖该模式的功能失效"（我们目前只用到发送/接收消息、群列表、登录状态，这些在默认模式下都是主路径）。

所以这个实验的准确表述是：**"从非默认的 hook 模式切回默认模式，看会话寿命是否变长"**，而不是"关掉 hook 防检测"。

## 如果切回 0 之后发送失败变多

先看 `status.ps1` 的 `lastPath`/`lastCause` 和 `kick-report.ps1` 的输出；如果出现大量 `1006514 网络连接异常` 而 `[KickedOffLine]` 没变，说明是发送链路受影响而不是风控变化，直接按下面的回滚步骤退回 1。
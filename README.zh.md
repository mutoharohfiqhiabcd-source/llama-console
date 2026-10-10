# llama-console

**通用的本地模型启动器**（Windows）。给 llama.cpp 套一个图形界面，把「找路径、敲参数、看显存、查日志」
变成双击一下，并顺带记录使用时长和 token。

不绑定任何具体模型 —— Qwen、Llama、Gemma、DeepSeek 蒸馏版，只要是 `.gguf` 都能用。

```
┌─ 本地模型控制台 ─────────────────────────────────┐
│  ● 运行中                     端口 8090 正在监听  │
│  模型：Qwen3.5-9B IQ4_XS                          │
│  别名：local-model                                │
│  显存：6014 / 8151 MiB                            │
│  配置：65536 上下文 · translate 模式              │
│  接口：http://127.0.0.1:8090/v1                   │
│  [启动模型][停止模型][重启模型][打开对话][API 文档]│
│  使用统计               今日 / 累计                │
│  使用时长      10 小时 49 分 / 47 小时 25 分       │
│  整机工时      23 小时 6 分 / 110 小时 2 分        │
│  本地生成      7,325 token / 7,325 token          │
│  本地提示      162,765 token / 162,765 token      │
│  运行日志                                          │
│  ┌──────────────────────────────────────────────┐ │
│  └──────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────┘
```

---

## 快速开始（三步）

```powershell
# 1. 改配置：只需要动这一个文件
notepad config.json

# 2. 安装（建桌面快捷方式 + 定时采样任务）
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

# 3. 双击桌面「本地模型控制台」
```

安装脚本会校验你的路径是否真实存在，路径错了会直接报错，不会让你双击半天没反应。

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

---

## 要配置什么

**全部配置都在 `config.json` 一个文件里，代码不用改。**

### 必填两项

| 字段 | 说明 |
|---|---|
| `llama.llamaServer` | `llama-server.exe` 的**完整路径** |
| `llama.model` | `.gguf` 模型文件的**完整路径** |

注意 JSON 里反斜杠要写两个：`"D:\\llama\\bin\\llama-server.exe"`。

### 常用项

| 字段 | 默认 | 说明 |
|---|---|---|
| `llama.displayName` | 模型文件名 | 界面上显示的名字 |
| `llama.alias` | `local-model` | API 里的模型 id，客户端填这个 |
| `llama.host` / `port` | `127.0.0.1` / `8090` | 监听地址。**只想本机用就别改成 0.0.0.0**，llama.cpp 默认无鉴权 |
| `llama.context` | `65536` | 上下文长度。8G 显存跑 9B 约能到 64k，12G 可上 128k |
| `llama.threads` | `8` | CPU 线程数。**混合架构（大小核）要给 P 核数**，给多了反而慢 |
| `llama.gpuLayers` | `999` | 全部层放 GPU。放不下就调小，或改用 CPU+GPU 混合 |
| `llama.mode` | `translate` | 用哪套采样参数，见下 |

### 采样参数：为什么分两套

`llama.modes` 里预置了两套，用 `llama.mode` 切换：

| | `translate`（翻译/精翻） | `creative`（写作） |
|---|---|---|
| temp | **0.2** | 0.85 |
| repeat-penalty | **1.0（关）** | 1.35 |
| presence / frequency | **0 / 0** | 0.2 / 0.2 |
| dry-multiplier | **0（关）** | 0.8 |

**这不是口味问题，是正确性问题。** 实测同一段游戏文本、同一个模型，只换采样参数：

| | 创作向参数 | 翻译向参数 |
|---|---|---|
| «The seal» | **封印 / 印记 / 密封装置**（三种漂移） | **封印**（全文一致） |
| «from Elara» | 「来自**她的**遗物」← 专名丢了 | 「来自**艾拉**的」 |
| 格式 | 某行冒号丢失 | 保持 |

原因：重复惩罚的机制是**惩罚重复 token**，可游戏/文档里同一个术语、同一个名字**反复出现才是对的**。
惩罚它等于逼模型换说法，于是术语漂移、专名丢失。

**结论：做翻译就把重复惩罚全关掉；写小说、写散文才开。** 想加自己的模式，在 `modes` 里加一段即可。

### `llama.extraArgs`

原样追加给 `llama-server` 的参数数组。默认值里有几个值得说明：

| 参数 | 作用 |
|---|---|
| `--metrics` | **使用统计必需**。llama.cpp 默认不开这个端点，删了就统计不到 token |
| `--reasoning-budget 0` | **立即结束思考**。9B 这类小模型默认会无限分析、从不产出正文（实测 1024 token 全在想、`content` 为空）。`-1` 是不限，别用 |
| `--cache-reuse 256` | 复用已热的 KV，重复前缀不用重新 prefill。默认是关的 |
| `--jinja` | 用模型自带的对话模板 |
| `-np 1` | 单并发。个人用够了，还能省显存 |

### `usage` 段

| 字段 | 说明 |
|---|---|
| `enabled` | 关掉就完全不统计 |
| `dshHome` | **留空则用 `~/.dsh`**。用 DeepSeek Harness 的话它自动统计会话时长和模型调用归属；不用 DSH 就填个不存在的路径，只统计 token |
| `dshWebPort` | DSH 网页端口，默认 3080 |
| `idleGapSeconds` | 相邻记录超过这个间隔算空闲，不计入使用时长。默认 300 秒 |
| `sampleIntervalMinutes` | 定时采样间隔，默认 10 分钟 |

---

## 界面

| 区域 | 内容 |
|---|---|
| 状态行 | 绿/黄/红状态灯、端口监听状态 |
| 信息区 | 模型名、别名、**显存实时读数**、当前上下文与模式、接口地址 |
| 按钮 | 启动 / 停止 / 重启 / 打开对话界面 / API 文档 |
| 使用统计 | 今日与累计，每 30 秒刷新 |
| 运行日志 | llama-server 输出，读不到 stdout 就显示 stderr |

桌面另外三个 bat：`启动模型.bat`（带控制台的纯命令行版）、`停止模型.bat`、`使用统计.bat`。

---

## 使用统计怎么算的

### 两个时间口径

| 指标 | 含义 |
|---|---|
| **使用时长** | 所有会话活跃区间的**并集** —— 真实墙钟时间，**不会超过 24 小时/天** |
| **整机工时** | 各会话活跃时长**累加** —— 并行跑多个 agent 时叠加，**可以超过墙钟** |

「活跃」的判据：同一会话内**相邻记录间隔 ≤ `idleGapSeconds`** 才算活跃，更长的间隔视为空闲。

调试时踩过两个坑，所以口径是这样定的：

1. **不能用「未闭合的 turn 算到现在」** —— 被遗弃的旧会话会各贡献几百小时。实测跑出过
   **11039 小时（460 天）**，而数据只有 54 天。
2. **不能直接累加各会话** —— 并行时墙钟被重复计算。实测 27 个会话并行时累加得 21.3 小时，
   而墙钟只有约 10 小时。

### token 从哪来

`llama-server /metrics` 的 Prometheus 计数器。注意它有两个特性：

- **是「自本次服务启动以来」的累计值**，重启即归零；
- **没有历史**，开启 `--metrics` 之前的推理无法补记。

所以统计器每次运行都记下当前值、和上次相减取增量再累加。计数器变小 = 检测到服务重启，
此时把当前值整体当增量（不会丢掉一整个服务的量）。

**因此定时采样是必需的**，不是可选优化：两次采样之间如果服务重启过，那段 token 就丢了。
`install.ps1` 会自动建这个任务：

```
任务名: LlamaConsole-Usage-Sample      默认每 10 分钟
手动查: schtasks /query  /tn "LlamaConsole-Usage-Sample" /fo list
手动删: schtasks /delete /tn "LlamaConsole-Usage-Sample" /f
```

### 命令行用法

```bat
node usage\track.mjs              采样一次 + 打印报表
node usage\track.mjs --report     只打印，不采样
node usage\track.mjs --days 14    每日明细显示 14 天
node usage\track.mjs --json       输出 JSON
node usage\track.mjs --quiet      静默采样
```

报表除今日/累计两栏外，还有**每日明细**，其中「模型 本地/云端」一列区分请求打到了本地还是云端 ——
这样一眼能看出"是不是真的在用本地模型"：

```
── 每日明细（最近 5 天）
日期        使用时长      整机工时      轮次   本地生成   本地提示   云端花费 模型 本地/云端
2026-10-08  1 小时 45 分  2 小时 45 分  30     0          0          ¥4.40    0 / 7
2026-10-09  6 小时 24 分  10 小时 9 分  92     0          0          ¥15.44   0 / 30
2026-10-10  10 小时 49 分 23 小时 6 分  127    7,325      162,765    ¥14.75   182 / 28
```

---

## 方法（原理简述）

### 启动器

`launcher.ps1` 是个 PowerShell + WinForms 程序，用 Windows 自带的 .NET，**不需要装任何运行时**。
它做三件事：

1. 读 `config.json`，把采样参数和参数数组拼成一条 llama-server 命令行，用 `Start-Process` 起进程，
   stdout/stderr 重定向到 `server.log` / `server.err.log`；
2. 每 2 秒轮询：端口是否在监听 + 进程是否存在 → 状态灯；`nvidia-smi` → 显存；日志尾部 → 日志区；
3. 开始/停止/重启都只是「杀进程」+「重新起」，参数来自配置，所以改配置后点「重启模型」就生效。

停止用的是 `Stop-Process`（按进程名抓 `llama-server`），不是杀 shell 子进程 —— 因为
`Start-Process` 起的是独立进程，杀父进程不会连带子进程。

### 统计器

`usage/track.mjs` 是纯 Node（只用内置模块，无依赖），三个数据源各取所长：

| 指标 | 来源 | 为什么要这样 |
|---|---|---|
| 本地 token | llama-server `/metrics` | DSH 会话记录里**不存** token 计数（实测搜遍 512 个会话、19 万条记录无 usage 字段） |
| 会话时长 / 轮次 / 模型归属 | DSH 会话记录 | 可全量重算，幂等，不怕重复计数 |
| 云端花费 | `~/.dsh/.dshw-usage.json` | 那是 DSH 余额插件的记录 |

DSH 的会话文件是 **zstd 多帧拼接**的（一个文件几百帧），Node 的流式解码器只解第一帧就报
`Unknown frame descriptor`，所以按 `28 B5 2F FD` 魔数切分逐帧解。

会话解析有缓存（按文件 `mtime` + `size` 判定），所以第一次跑要几秒，之后通常 1 秒内。

---

## 常见问题

**Q：双击没反应 / 窗口闪一下就没了**
在 PowerShell 里直接跑 `powershell -File launcher.ps1 -CheckConfig` 看配置有没有问题。
配置里的路径不存在会直接报出来。

**Q：显存读取失败**
没装 NVIDIA 驱动或没有独显。不影响使用，只是那行显示"读取失败"。

**Q：token 一直是 0**
三种可能：① `extraArgs` 里删了 `--metrics`；② 服务刚重启还没跑过推理；
③ 定时任务没建，而服务重启过（增量丢了）。用 `-CheckConfig` 能看到 `--metrics` 在不在。

**Q：使用时长看着偏大**
`idleGapSeconds` 调小（比如 120）。它决定「多久没动静就算离开」。

**Q：中文在命令行里是乱码**
`使用统计.bat` 里已经 `chcp 65001`。如果你自己调 `node usage\track.mjs`，
先 `chcp 65001`，或在 Windows Terminal 里跑。

**Q：模型加载失败 / 显存不够**
把 `llama.gpuLayers` 从 999 调到比如 20，让一部分层留在 CPU；或把 `llama.context` 调小。

---

## 目录结构

```
llama-console/
├── config.json         ← 唯一要改的文件
├── launcher.ps1        图形界面（读 config.json）
├── install.ps1         安装/卸载
├── usage/
│   ├── track.mjs       统计器（Node，无依赖）
│   ├── sample.bat      定时任务调用（install 时生成）
│   └── usage.json      数据（install 后生成）
├── server.log          运行日志（运行时生成）
└── server.err.log
```

安装后桌面会多出：`本地模型控制台.lnk`、`启动模型.bat`、`停止模型.bat`、`使用统计.bat`。

---

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带）
- [llama.cpp](https://github.com/ggml-org/llama.cpp) 的 Windows 预编译包（CUDA / Vulkan / CPU 都行）
- Node.js 18+（**只有使用统计需要**，不用统计可以不装）
  - 会话文件是 zstd 压缩的，Node 22+ 才内置 zstd 解码；低于 22 版本统计器会退化为只统计 token

## 许可

MIT

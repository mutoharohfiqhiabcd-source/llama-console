# llama-console

A **generic local-model launcher for Windows**. Gives [llama.cpp](https://github.com/ggml-org/llama.cpp)
a GUI: start/stop, live VRAM, live logs — plus usage tracking (time and tokens).

Not tied to any particular model. Anything that ships as a `.gguf` works.

> 中文文档见 [README.zh.md](README.zh.md) —— 更详细，包含采样参数为什么分两套的实测数据。

---

## Quick start

```powershell
# 1. Edit the only file you need to edit
notepad config.json

# 2. Install (desktop shortcuts + scheduled sampling task)
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

# 3. Double-click "本地模型控制台" on the desktop
```

Uninstall:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

---

## What you configure

Everything lives in `config.json`. The code never needs editing.

**Required:**

| Field | Meaning |
|---|---|
| `llama.llamaServer` | full path to `llama-server.exe` |
| `llama.model` | full path to the `.gguf` |

(Backslashes must be doubled in JSON: `"D:\\llama\\bin\\llama-server.exe"`.)

**Common:**

| Field | Default | Notes |
|---|---|---|
| `llama.alias` | `local-model` | the model id your client sends |
| `llama.host` / `port` | `127.0.0.1` / `8090` | do **not** use `0.0.0.0` unless you know llama.cpp has no auth by default |
| `llama.context` | `65536` | a 9B at Q4 fits ~64k on 8 GB VRAM |
| `llama.threads` | `8` | on hybrid CPUs (P+E cores) set this to the **P-core count** — more is slower |
| `llama.gpuLayers` | `999` | lower it if the model doesn't fit |
| `llama.mode` | `translate` | which sampling preset to use |

### Two sampling presets, and why it matters

`llama.modes` ships two presets; pick one with `llama.mode`.

| | `translate` | `creative` |
|---|---|---|
| temp | **0.2** | 0.85 |
| repeat-penalty | **1.0 (off)** | 1.35 |
| presence / frequency | **0 / 0** | 0.2 / 0.2 |
| dry-multiplier | **0 (off)** | 0.8 |

This is a **correctness** issue, not taste. Measured on the same game text with the same model,
changing only the sampling:

| | creative params | translation params |
|---|---|---|
| «The seal» | **three different renderings** | **consistent** |
| «from Elara» | proper noun dropped | proper noun kept |

Repetition penalties punish repeated tokens — but in game text and documentation, the same term
and the same name **repeating is correct**. Penalising it forces the model to vary its wording,
which shows up as terminology drift and dropped proper nouns.

**Turn every repetition penalty off for translation; turn them on for prose.**

### `llama.extraArgs`

Passed through to `llama-server` verbatim. Two entries are load-bearing:

- **`--metrics`** — required by usage tracking. llama.cpp does not expose the endpoint by default.
- **`--reasoning-budget 0`** — ends thinking immediately. Small models otherwise analyse forever and
  never emit content (measured: 1024 tokens of pure reasoning, empty `content`). `-1` means unlimited.

---

## Usage tracking

Two time metrics, because parallel agents make them differ:

| Metric | Meaning |
|---|---|
| **使用时长 / active time** | union of all session activity intervals — real wall clock, **never exceeds 24 h/day** |
| **整机工时 / total agent work** | per-session time summed — parallel teammates stack, **can exceed wall clock** |

Tokens come from `llama-server /metrics`. That counter is **cumulative since the current server
start** and resets on restart, so the tracker samples it and accumulates deltas. Hence the scheduled
task is **required, not optional** — tokens generated between two samples are lost if the server
restarted in between.

```bat
node usage\track.mjs              sample + report
node usage\track.mjs --report     report only
node usage\track.mjs --days 14    daily breakdown for 14 days
node usage\track.mjs --quiet      silent sample (used by the scheduled task)
```

The daily table includes a **local / cloud** split, so you can see at a glance whether requests
actually went to your local model.

---

## How it works

**Launcher** — PowerShell + WinForms, using the .NET that ships with Windows (no runtime to install).
It reads `config.json`, assembles one llama-server command line, launches it with redirected
stdout/stderr, then polls every 2 s: port + process for the status light, `nvidia-smi` for VRAM,
log tail for the log pane. "Restart" is just kill + relaunch, so editing the config and hitting
restart is enough — no reinstall.

**Tracker** — plain Node, built-in modules only, no dependencies. It merges three sources because
no single one has everything: DSH session records store **no token counts** (verified across 512
sessions / 190k records), so local tokens must come from llama.cpp's metrics endpoint.

DSH session files are **concatenated zstd frames** (hundreds per file); Node's streaming decoder
stops at the first frame with `Unknown frame descriptor`, so frames are split on the `28 B5 2F FD`
magic and decoded individually.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 (built in)
- a llama.cpp Windows build (CUDA / Vulkan / CPU)
- Node.js 22.15+ — **only for usage tracking**; Node 22+ ships zstd, needed to read DSH sessions.
  Without a DSH install the tracker still reports llama.cpp tokens, so Node 18+ is fine there.

## License

MIT

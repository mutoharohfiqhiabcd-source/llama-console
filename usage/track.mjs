#!/usr/bin/env node
// =============================================================================
//  使用统计  usage/track.mjs
//
//  统计「使用时间」和「token」，分今日 / 累计。配置全在同目录上级的 config.json。
//
//  数据源：
//    1. llama-server /metrics    → 本地模型 token（权威计数器，需 --metrics）
//    2. DSH 会话记录（可选）      → 会话活跃时长与模型调用归属
//    3. DSH 花费文件（可选）      → 云端 API 花费
//
//  用法：
//    node usage/track.mjs              采样一次 + 打印报表
//    node usage/track.mjs --report     只打印，不采样
//    node usage/track.mjs --days 14    每日明细显示 14 天
//    node usage/track.mjs --json       输出 JSON
//    node usage/track.mjs --quiet      静默采样（给定时任务用）
// =============================================================================

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'
import { zstdDecompressSync } from 'node:zlib'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = dirname(HERE)
const CONFIG_PATH = join(ROOT, 'config.json')
const USAGE_FILE = join(HERE, 'usage.json')

// ---------------------------------------------------------------- 配置
function readConfig() {
  const d = {
    llama: { host: '127.0.0.1', port: 8090 },
    usage: { enabled: true, dshHome: '', dshWebPort: 3080, idleGapSeconds: 300 },
  }
  try {
    const c = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'))
    return { ...d, ...c, llama: { ...d.llama, ...c.llama }, usage: { ...d.usage, ...c.usage } }
  } catch {
    return d
  }
}
const CFG = readConfig()
const METRICS = `http://${CFG.llama.host || '127.0.0.1'}:${CFG.llama.port || 8090}/metrics`
const IDLE_GAP = Number(CFG.usage.idleGapSeconds) || 300
const DSH_HOME = CFG.usage.dshHome
  ? CFG.usage.dshHome.replace(/^~(?=$|[\\/])/, homedir())
  : join(homedir(), '.dsh')
const SESSIONS = join(DSH_HOME, 'sessions')
const CLOUD_USAGE = join(DSH_HOME, '.dshw-usage.json')
const HAS_DSH = existsSync(SESSIONS)
const CACHE_V = 4

const argv = process.argv.slice(2)
const REPORT_ONLY = argv.includes('--report')
const JSON_ONLY = argv.includes('--json')
const QUIET = argv.includes('--quiet')
const di = argv.indexOf('--days')
const DAYS = di >= 0 ? Math.max(1, parseInt(argv[di + 1], 10) || 7) : 7

// ---------------------------------------------------------------- 工具
const pad = (s, n) => String(s).padStart(n, '0')
const dispW = (s) => {
  let w = 0
  for (const ch of String(s)) w += /[\u1100-\u115F\u2E80-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6]/.test(ch) ? 2 : 1
  return w
}
const padW = (s, n) => String(s) + ' '.repeat(Math.max(0, n - dispW(s)))
const localDay = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}` }
const fmtDur = (sec) => {
  sec = Math.round(sec || 0)
  if (sec < 60) return `${sec} 秒`
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60)
  return h === 0 ? `${m} 分` : `${h} 小时 ${m} 分`
}
const fmtNum = (n) => (n || 0).toLocaleString('en-US')
const mergeIntervals = (ivs) => {
  if (!ivs || ivs.length === 0) return []
  const s = [...ivs].sort((a, b) => a[0] - b[0])
  const out = [s[0].slice()]
  for (let i = 1; i < s.length; i++) {
    const cur = s[i], last = out[out.length - 1]
    if (cur[0] <= last[1]) { if (cur[1] > last[1]) last[1] = cur[1] } else out.push(cur.slice())
  }
  return out
}
function emptyDay() {
  return {
    localPromptTokens: 0, localGeneratedTokens: 0, localCachedTokens: 0, localServerSeconds: 0,
    sessionActiveSeconds: 0, sessionWorkSeconds: 0, sessionTurns: 0, deepseekCny: 0,
  }
}

function loadUsage() {
  let u = { version: 1, updatedAt: null, days: {}, sample: null, sessionCache: {} }
  if (existsSync(USAGE_FILE)) {
    try { u = JSON.parse(readFileSync(USAGE_FILE, 'utf8')) } catch { /* 坏文件就当新的 */ }
  }
  u.days ||= {}; u.sessionCache ||= {}; u.sample ||= null
  // 迁移：早期版本 pad() 用空格填充，产生过 "2026-10- 3"，与 "2026-10-03" 分裂成两天
  const norm = {}
  for (const [k, v] of Object.entries(u.days)) {
    const m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(k)
    const key = m ? `${m[1]}-${pad(m[2], 2)}-${pad(m[3], 2)}` : k
    norm[key] ||= emptyDay()
    const dst = norm[key]
    for (const [f, val] of Object.entries(v || {})) {
      if (f === 'modelRequests') {
        dst.modelRequests ||= {}
        for (const [mk, mn] of Object.entries(val || {})) dst.modelRequests[mk] = (dst.modelRequests[mk] || 0) + mn
      } else if (typeof val === 'number') {
        const recomputed = f === 'sessionActiveSeconds' || f === 'sessionWorkSeconds' || f === 'sessionTurns' || f === 'localServerSeconds'
        dst[f] = recomputed ? Math.max(dst[f] || 0, val) : (dst[f] || 0) + val
      }
    }
  }
  u.days = norm
  return u
}

// ---------------------------------------------------------------- 1. 本地 token
async function sampleMetrics() {
  try {
    const res = await fetch(METRICS, { signal: AbortSignal.timeout(5000) })
    if (!res.ok) return null
    const text = await res.text()
    const grab = (n) => {
      const m = text.match(new RegExp('^' + n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s+([\\d.eE+-]+)$', 'm'))
      return m ? Number(m[1]) : 0
    }
    return {
      prompt: grab('llamacpp:prompt_tokens_total'),
      generated: grab('llamacpp:tokens_predicted_total'),
      cached: grab('llamacpp:prompt_tokens_cached_total'),
    }
  } catch { return null }
}

// ---------------------------------------------------------------- 2. 会话
function readZstdFrames(file) {
  const buf = readFileSync(file)
  const magic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
  const offs = []
  let i = 0
  while (true) { const k = buf.indexOf(magic, i); if (k < 0) break; offs.push(k); i = k + 1 }
  let text = ''
  for (let n = 0; n < offs.length; n++) {
    const s = offs[n], e = n + 1 < offs.length ? offs[n + 1] : buf.length
    try { text += zstdDecompressSync(buf.subarray(s, e)).toString('utf8') } catch { /* 坏帧跳过 */ }
  }
  return text
}
function listSessionFiles(dir, depth = 0, out = []) {
  if (depth > 4) return out
  let ents = []
  try { ents = readdirSync(dir, { withFileTypes: true }) } catch { return out }
  for (const e of ents) {
    const p = join(dir, e.name)
    if (e.isDirectory()) listSessionFiles(p, depth + 1, out)
    else if (e.name.endsWith('.zstd')) out.push(p)
  }
  return out
}
function scanSessions(cache) {
  const files = listSessionFiles(SESSIONS)
  const perDay = {}
  let reparsed = 0, reused = 0
  for (const f of files) {
    const st = statSync(f)
    const key = basename(dirname(f))
    const hit = cache[key]
    if (hit && hit.v === CACHE_V && hit.mtimeMs === st.mtimeMs && hit.size === st.size) {
      reused++
      for (const [d, ivs] of Object.entries(hit.perDay)) { perDay[d] ||= []; for (const iv of ivs) perDay[d].push(iv) }
      continue
    }
    let text
    try { text = readZstdFrames(f) } catch { continue }
    reparsed++
    const times = [], turnsByDay = {}, modelsByDay = {}
    for (const line of text.split('\n')) {
      if (!line) continue
      let o
      try { o = JSON.parse(line) } catch { continue }
      if (typeof o.time === 'number') times.push(o.time)
      if (o.type === 'turn/start' && typeof o.time === 'number') {
        const d = localDay(o.time); turnsByDay[d] = (turnsByDay[d] || 0) + 1
      }
      if (o.type === 'request/header' && typeof o.time === 'number') {
        const c = o.data?.header?.config
        if (c) {
          const d = localDay(o.time), k = `${c.provider || '?'} / ${c.model || '?'}`
          modelsByDay[d] ||= {}; modelsByDay[d][k] = (modelsByDay[d][k] || 0) + 1
        }
      }
    }
    times.sort((a, b) => a - b)
    // 活跃时长 = 相邻记录间隔 ≤ IDLE_GAP 的那些段。不依赖 turn 是否闭合，
    // 被遗弃的旧会话也不会虚增几百小时。
    const raw = {}
    for (let i = 1; i < times.length; i++) {
      const gap = (times[i] - times[i - 1]) / 1000
      if (gap > 0 && gap <= IDLE_GAP) {
        const d = localDay(times[i - 1]); raw[d] ||= []; raw[d].push([times[i - 1], times[i]])
      }
    }
    const per = {}
    for (const [d, ivs] of Object.entries(raw)) per[d] = mergeIntervals(ivs)
    for (const d of Object.keys(turnsByDay)) per[d] ||= []
    cache[key] = { v: CACHE_V, mtimeMs: st.mtimeMs, size: st.size, perDay: per, turns: turnsByDay, models: modelsByDay }
    for (const [d, ivs] of Object.entries(per)) { perDay[d] ||= []; for (const iv of ivs) perDay[d].push(iv) }
  }
  const turnsByDay = {}, modelsByDay = {}
  for (const v of Object.values(cache)) {
    for (const [d, n] of Object.entries(v.turns || {})) turnsByDay[d] = (turnsByDay[d] || 0) + n
    for (const [d, mm] of Object.entries(v.models || {})) {
      modelsByDay[d] ||= {}
      for (const [k, n] of Object.entries(mm)) modelsByDay[d][k] = (modelsByDay[d][k] || 0) + n
    }
  }
  const byDay = {}
  for (const [d, ivs] of Object.entries(perDay)) {
    const merged = mergeIntervals(ivs)
    byDay[d] = {
      activeSeconds: merged.reduce((s, [a, b]) => s + (b - a) / 1000, 0),
      workSeconds: ivs.reduce((s, [a, b]) => s + (b - a) / 1000, 0),
    }
  }
  return { byDay, turnsByDay, modelsByDay, files: files.length, reparsed, reused }
}

// ---------------------------------------------------------------- 3. 云端花费
function readCloudSpend() {
  try {
    const doc = JSON.parse(readFileSync(CLOUD_USAGE, 'utf8'))
    const out = {}
    for (const [d, v] of Object.entries(doc.history || {})) out[d] = Number(v) || 0
    for (const book of Object.values(doc.accounting?.books || {})) {
      for (const [d, v] of Object.entries(book.days || {})) {
        if (typeof v?.debitUnits === 'number') out[d] = v.debitUnits / 1e8
      }
    }
    return out
  } catch { return {} }
}

// ---------------------------------------------------------------- 主流程
const usage = loadUsage()
for (const [d, v] of Object.entries(usage.days)) usage.days[d] = { ...emptyDay(), ...v }

const now = Date.now()
const today = localDay(now)
const metrics = await sampleMetrics()
const sess = HAS_DSH ? scanSessions(usage.sessionCache) : { byDay: {}, turnsByDay: {}, modelsByDay: {}, files: 0, reparsed: 0, reused: 0 }
const cloud = HAS_DSH ? readCloudSpend() : {}

for (const [d, v] of Object.entries(sess.byDay)) {
  usage.days[d] ||= emptyDay()
  usage.days[d].sessionActiveSeconds = Math.round(v.activeSeconds)
  usage.days[d].sessionWorkSeconds = Math.round(v.workSeconds)
  usage.days[d].sessionTurns = sess.turnsByDay[d] || 0
}
for (const [d, mm] of Object.entries(sess.modelsByDay)) {
  usage.days[d] ||= emptyDay()
  usage.days[d].modelRequests = mm
}
for (const [d, n] of Object.entries(sess.turnsByDay)) {
  usage.days[d] ||= emptyDay()
  if (!sess.byDay[d]) usage.days[d].sessionTurns = n
}
for (const [d, v] of Object.entries(cloud)) {
  usage.days[d] ||= emptyDay()
  usage.days[d].deepseekCny = Math.round(v * 100) / 100
}

if (!REPORT_ONLY && CFG.usage.enabled !== false) {
  usage.days[today] ||= emptyDay()
  const day = usage.days[today]
  const prev = usage.sample
  if (metrics) {
    // /metrics 是「自本次启动以来」的累计值，重启归零 → 变小即视为重启，当前值整体当增量
    if (prev && prev.serverUp && metrics.prompt >= prev.prompt && metrics.generated >= prev.generated) {
      day.localPromptTokens += metrics.prompt - prev.prompt
      day.localGeneratedTokens += metrics.generated - prev.generated
      day.localCachedTokens += metrics.cached - prev.cached
      day.localServerSeconds += Math.round((now - prev.at) / 1000)
    } else {
      day.localPromptTokens += metrics.prompt
      day.localGeneratedTokens += metrics.generated
      day.localCachedTokens += metrics.cached
    }
    usage.sample = { at: now, serverUp: true, prompt: metrics.prompt, generated: metrics.generated, cached: metrics.cached }
  } else {
    usage.sample = { at: now, serverUp: false, prompt: 0, generated: 0, cached: 0 }
  }
  usage.updatedAt = new Date(now).toISOString()
  usage.today = today
  mkdirSync(HERE, { recursive: true })
  writeFileSync(USAGE_FILE, JSON.stringify(usage, null, 2), 'utf8')
}

// ---------------------------------------------------------------- 报表
const days = Object.keys(usage.days).sort()
const activeDays = days.filter((d) => (usage.days[d].sessionActiveSeconds || 0) > 0 || (usage.days[d].localPromptTokens || 0) > 0)
const sum = () => {
  const t = emptyDay()
  for (const d of days) for (const k of Object.keys(t)) t[k] += usage.days[d][k] || 0
  return t
}
const todayV = usage.days[today] || emptyDay()
const totalV = sum()

if (QUIET) {
  // 静默
} else if (JSON_ONLY) {
  console.log(JSON.stringify({ today, todayV, totalV, days: days.length, sessions: sess.files }, null, 2))
} else {
  const line = (label, a, b) => `  ${padW(label, 16)} ${String(a).padStart(18)} ${String(b).padStart(18)}`
  console.log('')
  console.log('  ╔══════════════════════════════════════════════════════════════════╗')
  console.log('  ║                      使 用 统 计                                 ║')
  console.log('  ╚══════════════════════════════════════════════════════════════════╝')
  console.log('')
  console.log(line('', `今日 ${today}`, `累计 ${days.length} 天`))
  console.log('  ' + '─'.repeat(54))
  console.log(line('使用时长', fmtDur(todayV.sessionActiveSeconds), fmtDur(totalV.sessionActiveSeconds)))
  console.log(line('  代理总工时', fmtDur(todayV.sessionWorkSeconds), fmtDur(totalV.sessionWorkSeconds)))
  console.log(line('会话轮次', fmtNum(todayV.sessionTurns), fmtNum(totalV.sessionTurns)))
  console.log(line('本地模型运行', fmtDur(todayV.localServerSeconds), fmtDur(totalV.localServerSeconds)))
  console.log('  ' + '─'.repeat(54))
  console.log(line('本地生成 token', fmtNum(todayV.localGeneratedTokens), fmtNum(totalV.localGeneratedTokens)))
  console.log(line('本地提示 token', fmtNum(todayV.localPromptTokens), fmtNum(totalV.localPromptTokens)))
  console.log(line('  其中命中缓存', fmtNum(todayV.localCachedTokens), fmtNum(totalV.localCachedTokens)))
  if (totalV.deepseekCny > 0) {
    console.log('  ' + '─'.repeat(54))
    console.log(line('云端花费', '¥' + todayV.deepseekCny.toFixed(2), '¥' + totalV.deepseekCny.toFixed(2)))
  }
  console.log('')
  if (!HAS_DSH) console.log('  注意：没找到 DSH 会话目录，只统计 llama-server 的 token。')
  console.log(`  数据文件: ${USAGE_FILE}`)
  if (!REPORT_ONLY) console.log(`  采样时间: ${new Date(now).toLocaleString('zh-CN')}`)

  const tail = days.slice(-DAYS)
  if (tail.length > 0) {
    console.log('')
    console.log(`  ── 每日明细（最近 ${tail.length} 天）`)
    const W = { d: 12, a: 14, w: 14, t: 7, g: 11, p: 11, c: 9 }
    console.log('  ' + padW('日期', W.d) + padW('使用时长', W.a) + padW('整机工时', W.w) +
      padW('轮次', W.t) + padW('本地生成', W.g) + padW('本地提示', W.p) + padW('云端花费', W.c) + '模型 本地/云端')
    for (const d of tail) {
      const v = usage.days[d]
      let loc = 0, cl = 0
      for (const [k, n] of Object.entries(v.modelRequests || {})) {
        if (/^llama\s*\//.test(k)) loc += n; else cl += n
      }
      console.log('  ' + padW(d, W.d) + padW(fmtDur(v.sessionActiveSeconds), W.a) +
        padW(fmtDur(v.sessionWorkSeconds), W.w) + padW(fmtNum(v.sessionTurns), W.t) +
        padW(fmtNum(v.localGeneratedTokens), W.g) + padW(fmtNum(v.localPromptTokens), W.p) +
        padW('¥' + (v.deepseekCny || 0).toFixed(2), W.c) + `${loc} / ${cl}`)
    }
  }
  console.log('')
}

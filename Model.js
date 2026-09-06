// Pure presentation logic for Vitals. No QML imports, no side effects:
// everything here is a plain function over plain data so the same code runs
// under Quickshell's JS engine and under `node test/model.test.js`.
//
// Levels: "normal" < "elevated" < "critical". The panel maps them to the
// theme's foreground, accent, and urgent colors respectively.

var LEVELS = ["normal", "elevated", "critical"]
var TEMP_WARN_C = 85
var TEMP_CRIT_C = 95

function clamp(value, low, high) {
  var n = Number(value)
  if (!isFinite(n)) return low
  return Math.max(low, Math.min(high, n))
}

// ---------------------------------------------------------------- formatting

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  var text = (i === 0 || n >= 100) ? String(Math.round(n)) : String(Math.round(n * 10) / 10)
  return text + " " + units[i]
}

function formatRate(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

function formatFreq(mhz) {
  var n = Number(mhz)
  if (!isFinite(n) || n <= 0) return "—"
  if (n >= 1000) return (Math.round(n / 100) / 10).toFixed(1) + " GHz"
  return Math.round(n) + " MHz"
}

function formatTemp(celsius, unit) {
  var n = Number(celsius)
  if (celsius === null || celsius === undefined || !isFinite(n)) return "—"
  if (String(unit || "C").toUpperCase() === "F") return Math.round(n * 9 / 5 + 32) + "°F"
  return Math.round(n) + "°C"
}

function formatUptime(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(s / 86400)
  var hours = Math.floor((s % 86400) / 3600)
  var minutes = Math.floor((s % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

function formatPercent(percent) {
  return Math.round(clamp(percent, 0, 100)) + "%"
}

function formatLoad(load) {
  if (!load || !load.length) return ""
  return (Math.round(Number(load[0]) * 100) / 100).toFixed(2)
}

// "12th Gen Intel(R) Core(TM) i7-1260P" -> "Intel Core i7-1260P"
function shortCpuModel(model) {
  var s = String(model || "")
  s = s.replace(/\((R|TM|C)\)/gi, "")
  s = s.replace(/\b\d+(st|nd|rd|th) Gen\b/i, "")
  s = s.replace(/\b(CPU|Processor)\b/gi, "")
  s = s.replace(/@.*$/, "")
  s = s.replace(/\b(w\/|with)\s+.*$/i, "")
  s = s.replace(/\b\d+-Core\b/i, "")
  return s.replace(/\s+/g, " ").trim()
}

// "Intel Core i7-1260P" -> "i7-1260P"; the hero line has one row to spend.
function compactCpuModel(model) {
  return shortCpuModel(model).replace(/^(Intel Core|Intel|AMD)\s+/i, "")
}

// ------------------------------------------------------------------- levels

function levelIndex(level) {
  var i = LEVELS.indexOf(level)
  return i < 0 ? 0 : i
}

function maxLevel(a, b) {
  return LEVELS[Math.max(levelIndex(a), levelIndex(b))]
}

function levelFor(percent, warn, crit) {
  var p = Number(percent)
  if (!isFinite(p)) return "normal"
  if (p >= Number(crit)) return "critical"
  if (p >= Number(warn)) return "elevated"
  return "normal"
}

function tempLevel(celsius) {
  if (celsius === null || celsius === undefined) return "normal"
  return levelFor(celsius, TEMP_WARN_C, TEMP_CRIT_C)
}

function overallLevel(doc, warn, crit) {
  var d = doc || {}
  var cpu = d.cpu || {}
  var memory = d.memory || {}
  var level = levelFor(cpu.percent, warn, crit)
  level = maxLevel(level, levelFor(memory.percent, warn, crit))
  level = maxLevel(level, tempLevel(cpu.tempC))
  return level
}

// Per-core meters sit up to sixteen to a row; beyond that, rows are balanced.
function meterColumns(count) {
  var n = Math.max(0, Math.floor(Number(count) || 0))
  if (n <= 16) return n
  return Math.ceil(n / Math.ceil(n / 16))
}

function busiestCore(cores) {
  var list = cores || []
  var best = -1, index = -1
  for (var i = 0; i < list.length; i++) {
    var v = Number(list[i])
    if (isFinite(v) && v > best) { best = v; index = i }
  }
  return index < 0 ? null : { index: index, percent: best }
}

// Label for the per-core disclosure row: "16 cores · busiest 42%" while the
// meters are hidden, just the count once they are showing.
function coresSummary(cores, expanded) {
  var list = cores || []
  var text = list.length + (list.length === 1 ? " core" : " cores")
  if (expanded) return text
  var busiest = busiestCore(list)
  return busiest ? text + " · busiest " + formatPercent(busiest.percent) : text
}

// ------------------------------------------------------------------ history

// Append a sample and drop everything older than the window.
function pushHistory(history, t, value, windowSec) {
  var time = Number(t)
  if (!isFinite(time)) return history || []
  var out = []
  var cutoff = time - Number(windowSec)
  var src = history || []
  for (var i = 0; i < src.length; i++) {
    if (src[i].t >= cutoff && src[i].t <= time) out.push(src[i])
  }
  out.push({ t: time, v: clamp(value, 0, 100) })
  return out
}

// Map history onto a width x height box, newest sample at the right edge.
// `pad` keeps the 0% and 100% lines inside the box.
function sparklinePoints(history, width, height, windowSec, pad) {
  var src = history || []
  var w = Number(width), h = Number(height), p = Number(pad) || 0
  if (src.length === 0 || !(w > 0) || !(h > 0)) return []
  var now = src[src.length - 1].t
  var start = now - Number(windowSec)
  var inner = Math.max(0, h - 2 * p)
  var out = []
  for (var i = 0; i < src.length; i++) {
    var x = clamp((src[i].t - start) / Number(windowSec), 0, 1) * w
    var y = p + (1 - clamp(src[i].v, 0, 100) / 100) * inner
    out.push({ x: x, y: y })
  }
  return out
}

// Close a polyline down to the baseline so it can be filled.
function sparklineArea(points, height) {
  if (!points || points.length < 2) return []
  var h = Number(height) || 0
  var out = [{ x: points[0].x, y: h }]
  for (var i = 0; i < points.length; i++) out.push(points[i])
  out.push({ x: points[points.length - 1].x, y: h })
  return out
}

// ------------------------------------------------------------ panel strings

function hostLine(doc) {
  var d = doc || {}
  var host = d.host || {}
  var parts = []
  var model = compactCpuModel(host.cpuModel)
  if (model) parts.push(model)
  if (host.threads > 0) parts.push(host.threads + " threads")
  if (d.uptimeSec > 0) parts.push("up " + formatUptime(d.uptimeSec))
  return parts.join(" · ")
}

function cpuDetail(cpu, unit) {
  var c = cpu || {}
  var parts = []
  if (c.freqMhz > 0) parts.push(formatFreq(c.freqMhz))
  if (c.tempC !== null && c.tempC !== undefined) parts.push(formatTemp(c.tempC, unit))
  var load = formatLoad(c.load)
  if (load) parts.push("load " + load)
  return parts.join(" · ")
}

function memoryDetail(memory) {
  var m = memory || {}
  if (!(m.totalBytes > 0)) return ""
  return formatBytes(m.usedBytes) + " of " + formatBytes(m.totalBytes)
}

function swapDetail(memory) {
  var m = memory || {}
  if (!(m.swapTotalBytes > 0)) return ""
  return formatBytes(m.swapUsedBytes) + " of " + formatBytes(m.swapTotalBytes)
}

// Fractions of the memory bar: `used` is drawn solid, `cached` is the
// translucent segment that follows it. Both are clamped so they never overrun.
function memoryFractions(memory) {
  var m = memory || {}
  var total = Number(m.totalBytes)
  if (!(total > 0)) return { used: 0, cached: 0 }
  var used = clamp(Number(m.usedBytes) / total, 0, 1)
  var cached = clamp(Number(m.cachedBytes) / total, 0, 1 - used)
  return { used: Math.round(used * 10000) / 10000, cached: Math.round(cached * 10000) / 10000 }
}

function gpuDetail(gpu, unit) {
  var g = gpu || {}
  var parts = []
  if (g.freqMhz > 0) parts.push(formatFreq(g.freqMhz) + (g.maxFreqMhz > 0 ? " of " + formatFreq(g.maxFreqMhz) : ""))
  else if (g.maxFreqMhz > 0) parts.push("clock parked · " + formatFreq(g.maxFreqMhz) + " max")
  if (g.vramTotalBytes > 0) parts.push(formatBytes(g.vramUsedBytes) + " of " + formatBytes(g.vramTotalBytes))
  if (g.tempC !== null && g.tempC !== undefined) parts.push(formatTemp(g.tempC, unit))
  return parts.join(" · ")
}

function storageValue(disk) {
  var d = disk || {}
  return formatBytes(d.freeBytes) + " free"
}

function storageDetail(disk) {
  var d = disk || {}
  return "of " + formatBytes(d.totalBytes) + " · " + Math.round(Number(d.percent) || 0) + "% used"
}

function hasPid(processes, pid) {
  var list = processes || []
  for (var i = 0; i < list.length; i++) if (list[i].pid === pid) return true
  return false
}

function signalArgs(helper, mode, pid) {
  return [helper, "--signal", mode === "kill" ? "kill" : "term", String(pid)]
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    LEVELS: LEVELS, TEMP_WARN_C: TEMP_WARN_C, TEMP_CRIT_C: TEMP_CRIT_C,
    clamp: clamp, formatBytes: formatBytes, formatRate: formatRate, formatFreq: formatFreq,
    formatTemp: formatTemp, formatUptime: formatUptime, formatPercent: formatPercent,
    formatLoad: formatLoad, shortCpuModel: shortCpuModel, compactCpuModel: compactCpuModel,
    levelIndex: levelIndex, maxLevel: maxLevel, levelFor: levelFor, tempLevel: tempLevel,
    overallLevel: overallLevel, meterColumns: meterColumns,
    busiestCore: busiestCore, coresSummary: coresSummary,
    pushHistory: pushHistory, sparklinePoints: sparklinePoints, sparklineArea: sparklineArea,
    hostLine: hostLine, cpuDetail: cpuDetail, memoryDetail: memoryDetail, swapDetail: swapDetail,
    memoryFractions: memoryFractions, gpuDetail: gpuDetail, storageValue: storageValue,
    storageDetail: storageDetail, hasPid: hasPid, signalArgs: signalArgs
  }
}

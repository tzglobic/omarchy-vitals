// Run with: node test/model.test.js
var M = require("../Model.js")

var failures = 0
function check(name, actual, expected) {
  var a = JSON.stringify(actual)
  var e = JSON.stringify(expected)
  if (a === e) return
  failures++
  console.error("FAIL " + name + "\n  expected " + e + "\n  actual   " + a)
}
function ok(name, condition) {
  if (condition) return
  failures++
  console.error("FAIL " + name)
}

var GB = 1024 * 1024 * 1024

// --- formatting
check("formatBytes zero", M.formatBytes(0), "0 B")
check("formatBytes garbage", M.formatBytes("nope"), "0 B")
check("formatBytes bytes", M.formatBytes(512), "512 B")
check("formatBytes KB", M.formatBytes(84 * 1024), "84 KB")
check("formatBytes one decimal", M.formatBytes(7.5 * GB), "7.5 GB")
check("formatBytes drops .0", M.formatBytes(8 * GB), "8 GB")
check("formatBytes no decimals past 100", M.formatBytes(412.4 * GB), "412 GB")
check("formatRate", M.formatRate(1.2 * 1024 * 1024), "1.2 MB/s")
check("formatRate zero", M.formatRate(0), "0 B/s")
check("formatFreq GHz", M.formatFreq(3200), "3.2 GHz")
check("formatFreq rounds", M.formatFreq(3249), "3.2 GHz")
check("formatFreq MHz", M.formatFreq(317), "317 MHz")
check("formatFreq missing", M.formatFreq(null), "—")
check("formatTemp C", M.formatTemp(64, "C"), "64°C")
check("formatTemp F", M.formatTemp(64, "F"), "147°F")
check("formatTemp lower-case unit", M.formatTemp(0, "f"), "32°F")
check("formatTemp missing", M.formatTemp(null, "C"), "—")
check("formatUptime minutes", M.formatUptime(45 * 60), "45m")
check("formatUptime hours", M.formatUptime(3 * 3600 + 12 * 60), "3h 12m")
check("formatUptime days", M.formatUptime(2 * 86400 + 4 * 3600), "2d 4h")
check("formatPercent rounds and clamps", M.formatPercent(101.4), "100%")
check("formatPercent undefined", M.formatPercent(undefined), "0%")
check("formatLoad", M.formatLoad([1.17, 1, 0.76]), "1.17")
check("formatLoad empty", M.formatLoad([]), "")

check("shortCpuModel intel", M.shortCpuModel("12th Gen Intel(R) Core(TM) i7-1260P"), "Intel Core i7-1260P")
check("shortCpuModel amd mobile", M.shortCpuModel("AMD Ryzen 7 7840U w/ Radeon 780M Graphics"), "AMD Ryzen 7 7840U")
check("shortCpuModel amd desktop", M.shortCpuModel("AMD Ryzen 9 7950X 16-Core Processor"), "AMD Ryzen 9 7950X")
check("shortCpuModel xeon", M.shortCpuModel("Intel(R) Xeon(R) CPU E5-2690 v4 @ 2.60GHz"), "Intel Xeon E5-2690 v4")
check("shortCpuModel empty", M.shortCpuModel(undefined), "")
check("compactCpuModel intel", M.compactCpuModel("12th Gen Intel(R) Core(TM) i7-1260P"), "i7-1260P")
check("compactCpuModel amd", M.compactCpuModel("AMD Ryzen 9 7950X 16-Core Processor"), "Ryzen 9 7950X")
check("compactCpuModel xeon", M.compactCpuModel("Intel(R) Xeon(R) CPU E5-2690 v4 @ 2.60GHz"), "Xeon E5-2690 v4")

// --- levels
check("levelFor normal", M.levelFor(10, 75, 90), "normal")
check("levelFor elevated at threshold", M.levelFor(75, 75, 90), "elevated")
check("levelFor critical at threshold", M.levelFor(90, 75, 90), "critical")
check("levelFor garbage", M.levelFor("x", 75, 90), "normal")
check("tempLevel null", M.tempLevel(null), "normal")
check("tempLevel hot", M.tempLevel(96), "critical")
check("maxLevel", M.maxLevel("elevated", "normal"), "elevated")
check("overallLevel worst wins", M.overallLevel({ cpu: { percent: 20, tempC: 60 }, memory: { percent: 92 } }, 75, 90), "critical")
check("overallLevel temperature alone", M.overallLevel({ cpu: { percent: 5, tempC: 88 }, memory: { percent: 30 } }, 75, 90), "elevated")
check("overallLevel empty", M.overallLevel({}, 75, 90), "normal")
check("overallLevel undefined", M.overallLevel(undefined, 75, 90), "normal")

check("meterColumns small", M.meterColumns(4), 4)
check("meterColumns sixteen in one row", M.meterColumns(16), 16)
check("meterColumns twenty-four balances rows", M.meterColumns(24), 12)
check("meterColumns thirty-two", M.meterColumns(32), 16)
check("meterColumns none", M.meterColumns(0), 0)
check("busiestCore", M.busiestCore([3, 42, 7]), { index: 1, percent: 42 })
check("busiestCore empty", M.busiestCore([]), null)
check("busiestCore ignores garbage", M.busiestCore(["x", 5]), { index: 1, percent: 5 })
check("coresSummary collapsed", M.coresSummary([3, 42, 7], false), "3 cores · busiest 42%")
check("coresSummary expanded", M.coresSummary([3, 42, 7], true), "3 cores")
check("coresSummary single", M.coresSummary([9], true), "1 core")
check("coresSummary none", M.coresSummary([], false), "0 cores")

// --- history
var h = M.pushHistory([], 100, 10, 60)
h = M.pushHistory(h, 130, 50, 60)
h = M.pushHistory(h, 170, 90, 60)
check("pushHistory drops samples outside the window", h.map(function(s) { return s.t }), [130, 170])
check("pushHistory clamps values", M.pushHistory([], 1, 140, 60)[0].v, 100)
check("pushHistory ignores bad time", M.pushHistory([{ t: 1, v: 1 }], "nope", 5, 60), [{ t: 1, v: 1 }])

var pts = M.sparklinePoints([{ t: 0, v: 0 }, { t: 60, v: 100 }], 100, 50, 60, 0)
check("sparklinePoints spans the box", pts, [{ x: 0, y: 50 }, { x: 100, y: 0 }])
var padded = M.sparklinePoints([{ t: 60, v: 100 }], 100, 50, 60, 5)
check("sparklinePoints honours padding", padded, [{ x: 100, y: 5 }])
check("sparklinePoints empty", M.sparklinePoints([], 100, 50, 60, 0), [])
check("sparklineArea closes to the baseline", M.sparklineArea(pts, 50), [{ x: 0, y: 50 }, { x: 0, y: 50 }, { x: 100, y: 0 }, { x: 100, y: 50 }])
check("sparklineArea needs two points", M.sparklineArea([{ x: 1, y: 1 }], 50), [])

// --- panel strings
var doc = {
  uptimeSec: 3 * 3600 + 12 * 60,
  host: { cpuModel: "12th Gen Intel(R) Core(TM) i7-1260P", threads: 16 },
  cpu: { percent: 12.3, freqMhz: 3200, tempC: 64, load: [1.17, 1, 0.76] },
  memory: { totalBytes: 16 * GB, usedBytes: 8 * GB, cachedBytes: 4 * GB, swapTotalBytes: 16 * GB, swapUsedBytes: 0.5 * GB },
  gpu: { available: true, name: "Iris Xe Graphics", percent: 12, freqMhz: 317, maxFreqMhz: 1400, vramUsedBytes: 0, vramTotalBytes: 0, tempC: null }
}
check("hostLine", M.hostLine(doc), "i7-1260P · 16 threads · up 3h 12m")
check("hostLine empty", M.hostLine({}), "")
check("cpuDetail", M.cpuDetail(doc.cpu, "C"), "3.2 GHz · 64°C · load 1.17")
check("cpuDetail sparse", M.cpuDetail({ percent: 3 }, "C"), "")
check("memoryDetail", M.memoryDetail(doc.memory), "8 GB of 16 GB")
check("memoryDetail empty", M.memoryDetail({}), "")
check("swapDetail", M.swapDetail(doc.memory), "512 MB of 16 GB")
check("swapDetail without swap", M.swapDetail({ swapTotalBytes: 0 }), "")
check("memoryFractions", M.memoryFractions(doc.memory), { used: 0.5, cached: 0.25 })
check("memoryFractions never overruns", M.memoryFractions({ totalBytes: 10, usedBytes: 8, cachedBytes: 8 }), { used: 0.8, cached: 0.2 })
check("memoryFractions empty", M.memoryFractions({}), { used: 0, cached: 0 })
check("gpuDetail", M.gpuDetail(doc.gpu, "C"), "317 MHz of 1.4 GHz")
check("gpuDetail parked clock", M.gpuDetail({ freqMhz: 0, maxFreqMhz: 1400 }, "C"), "clock parked · 1.4 GHz max")
check("gpuDetail missing clock is not parked", M.gpuDetail({ freqMhz: null, maxFreqMhz: 1400 }, "C"), "1.4 GHz max")
check("gpuDetail discrete", M.gpuDetail({ freqMhz: 1800, maxFreqMhz: 2500, vramUsedBytes: GB, vramTotalBytes: 8 * GB, tempC: 55 }, "C"), "1.8 GHz of 2.5 GHz · 1 GB of 8 GB · 55°C")
check("storageValue", M.storageValue({ freeBytes: 412 * GB }), "412 GB free")
check("storageDetail", M.storageDetail({ totalBytes: 953 * GB, percent: 43.2 }), "of 953 GB · 43% used")
ok("hasPid finds", M.hasPid([{ pid: 4 }, { pid: 9 }], 9))
ok("hasPid misses", !M.hasPid([{ pid: 4 }], 9))
check("signalArgs term", M.signalArgs("/x/omarchy-vitals", "term", 123, "456"), ["/x/omarchy-vitals", "--signal", "term", "123", "--start-time", "456"])
check("signalArgs kill", M.signalArgs("/x/omarchy-vitals", "kill", 5, "789"), ["/x/omarchy-vitals", "--signal", "kill", "5", "--start-time", "789"])
ok("hasPid matches identity", M.hasPid([{ pid: 4, startTime: "123" }], 4, "123"))
ok("hasPid rejects reused pid", !M.hasPid([{ pid: 4, startTime: "456" }], 4, "123"))
check("gpuDetail unknown VRAM is not zero usage", M.gpuDetail({ vramTotalBytes: GB, vramUsedBytes: null }, "C"), "")
check("signalArgs unknown mode falls back to term", M.signalArgs("h", "nuke", 5)[2], "term")

if (failures > 0) {
  console.error(failures + " failure(s)")
  process.exit(1)
}
console.log("model.test.js: all checks passed")

// A small LiveView hook around echarts (story 1092): the server sends the
// whole chart option as JSON on `data-option`, and this only ever hands it to
// echarts -- no metric logic lives here.
//
// echarts is vendored (/vendor/echarts.min.js), like sigma, because this repo
// has no npm install step: importing the npm package failed the bundle, and
// every page fell back to a stale app.js (2026-10-12). Loaded on first use
// rather than from the root layout, so pages without a chart don't pay for it.
//
// Story starts and promotions ride as `markLine` entries on the first
// series rather than as their own series, so they render as vertical
// event markers instead of chart lines (criterion 2031).
let loading = null

function loadEcharts() {
  if (window.echarts) return Promise.resolve(window.echarts)

  loading ||= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "/vendor/echarts.min.js"
    script.onload = () => resolve(window.echarts)
    script.onerror = reject
    document.head.appendChild(script)
  })

  return loading
}

export const EChart = {
  mounted() {
    loadEcharts().then((echarts) => {
      if (this.disposed) return
      this.chart = echarts.init(this.el)
      const data = this.readData()
      this.chart.setOption(toOption(data))
      // A bar that names something can pick it: the server is told which.
      if (data.pick_event) {
        this.chart.on("click", (params) => {
          const id = (data.ids || [])[params.dataIndex]
          if (id) this.pushEvent(data.pick_event, { id })
        })
      }
      this.onResize = () => this.chart.resize()
      window.addEventListener("resize", this.onResize)
    })
  },
  readData() {
    return JSON.parse(this.el.dataset.option)
  },
  destroyed() {
    this.disposed = true
    if (this.onResize) window.removeEventListener("resize", this.onResize)
    if (this.chart) this.chart.dispose()
  },
}

function toOption(data) {
  if (data.kind === "bars") return barsOption(data)

  const categories = data.categories || []
  const series = data.series || []
  // A marker's label is just the story number -- full titles overlapped into
  // an unreadable band. The title is on hover.
  const markLineData = (data.events || []).map((event) => {
    const name = [event.type.replace("_", " "), event.number && `#${event.number}`, event.title]
      .filter(Boolean)
      .join(" ")

    return {
      name,
      xAxis: nearestCategoryIndex(categories, event.at),
      label: { formatter: event.number ? `#${event.number}` : "", fontSize: 10 },
      // Hovering the line spells it out in place, whatever the tooltip does.
      emphasis: { label: { formatter: name } },
    }
  })

  // Only the scales this chart's series use: the rates chart has one, and the
  // first axis drawn sits on the left.
  const used = new Set(series.map((one) => one.y_axis))
  const axes = AXES.filter((axis) => used.has(axis.key)).map((axis, index) =>
    index === 0 ? { ...axis, position: "left", offset: 0 } : axis
  )

  return {
    tooltip: { trigger: "axis" },
    legend: {},
    grid: { left: 64, right: 24 + 56 * Math.max(axes.length - 1, 0) },
    xAxis: { type: "category", data: categories },
    yAxis: axes.map(({ key: _key, ...axis }) => ({ type: "value", ...axis })),
    series: series.map((one, index) => {
      const placed = { ...one, yAxisIndex: axisIndex(axes, one.y_axis), ...tooltipFor(one) }
      const markLine = {
        symbol: "none",
        data: markLineData,
        tooltip: { trigger: "item", formatter: (params) => escapeHtml(params.name) },
      }
      return index === 0 ? { ...placed, markLine } : placed
    }),
  }
}

// Tokens run to millions, messages and failed turns are single digits and the
// tool failure rate is a fraction, so each gets its own scale. On one axis
// everything but tokens sat flat on zero.
const AXES = [
  { key: "tokens", name: "Tokens", position: "left", axisLabel: { formatter: compact } },
  { key: "count", name: "Count", position: "right", minInterval: 1 },
  {
    key: "rate",
    name: "Rate",
    position: "right",
    offset: 56,
    min: 0,
    max: 1,
    splitLine: { show: false },
    axisLabel: { formatter: (value) => `${+(value * 100).toFixed(1)}%` },
  },
]

function tooltipFor(series) {
  if (series.y_axis !== "rate") return {}
  return { tooltip: { valueFormatter: (v) => (v == null ? "-" : `${(v * 100).toFixed(1)}%`) } }
}

function axisIndex(axes, key) {
  const index = axes.findIndex((axis) => axis.key === key)
  return index < 0 ? 0 : index
}

function compact(value) {
  if (value >= 1e6) return `${+(value / 1e6).toFixed(1)}M`
  if (value >= 1e3) return `${+(value / 1e3).toFixed(1)}k`
  return `${value}`
}

function nearestCategoryIndex(categories, iso) {
  const at = new Date(iso).getTime()
  let bestIndex = 0
  let bestDiff = Infinity

  categories.forEach((category, index) => {
    const diff = Math.abs(new Date(category).getTime() - at)
    if (diff < bestDiff) {
      bestDiff = diff
      bestIndex = index
    }
  })

  return bestIndex
}

// Horizontal stacked bars, one per category: a story's stage times, or the
// hours spent waiting on each kind of holder. `details` are the category's own
// lines for the tooltip -- what a card per story used to list.
function barsOption(data) {
  const details = data.details || []
  const unit = data.unit || ""

  return {
    tooltip: {
      trigger: "axis",
      axisPointer: { type: "shadow" },
      confine: true,
      formatter: (params) => {
        const index = params[0] ? params[0].dataIndex : 0
        const lines = [`<strong>${escapeHtml(params[0] ? params[0].name : "")}</strong>`]
        params.forEach((p) => {
          if (p.value) lines.push(`${p.marker}${escapeHtml(p.seriesName)}: ${p.value}${unit}`)
        })
        ;(details[index] || []).forEach((line) => lines.push(escapeHtml(line)))
        return lines.join("<br>")
      },
    },
    legend: {},
    grid: { left: 8, right: 24, top: 36, bottom: 8, containLabel: true },
    xAxis: { type: "value", axisLabel: { formatter: (value) => `${value}${unit}` } },
    yAxis: {
      type: "category",
      inverse: true,
      data: data.categories || [],
      axisLabel: { width: 240, overflow: "truncate" },
    },
    series: (data.stacks || []).map((stack) => ({
      name: stack.name,
      type: "bar",
      stack: stack.stack || "total",
      data: stack.data,
      ...(stack.color ? { itemStyle: { color: stack.color } } : {}),
    })),
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
}

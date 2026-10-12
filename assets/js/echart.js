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
      this.chart.setOption(toOption(this.readData()))
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
  const categories = data.categories || []
  const series = data.series || []
  const markLineData = (data.events || []).map((event) => ({
    name: event.type,
    xAxis: nearestCategoryIndex(categories, event.at),
    label: { formatter: event.title ? `${event.type}: ${event.title}` : event.type },
  }))

  return {
    tooltip: { trigger: "axis" },
    legend: {},
    xAxis: { type: "category", data: categories },
    yAxis: [{ type: "value" }],
    series: series.map((one, index) =>
      index === 0 ? { ...one, markLine: { symbol: "none", data: markLineData } } : one
    ),
  }
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

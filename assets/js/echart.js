import * as echarts from "echarts"

// A small LiveView hook around the echarts npm package (story 1092): the
// server sends the whole chart option as JSON on `data-option`, and this
// only ever hands it to echarts -- no metric logic lives here.
//
// Story starts and promotions ride as `markLine` entries on the first
// series rather than as their own series, so they render as vertical
// event markers instead of chart lines (criterion 2031).
export const EChart = {
  mounted() {
    this.chart = echarts.init(this.el)
    this.chart.setOption(toOption(this.readData()))
    this.onResize = () => this.chart.resize()
    window.addEventListener("resize", this.onResize)
  },
  readData() {
    return JSON.parse(this.el.dataset.option)
  },
  destroyed() {
    window.removeEventListener("resize", this.onResize)
    this.chart.dispose()
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

import * as echarts from "../vendor/echarts.min.js"

const colors = {
  Claimed: "#22c55e", Ignored: "#f59e0b", Declined: "#ef4444",
  Undelivered: "#a855f7", Open: "#3b82f6", Superseded: "#94a3b8",
  Expired: "#64748b", "N a": "#14b8a6",
}

export const OfferResults = {
  mounted() {
    this.chart = echarts.init(this.el, null, { renderer: "svg" })
    this.draw()
    this.resizeObserver = new ResizeObserver(() => this.chart.resize())
    this.resizeObserver.observe(this.el)
  },
  updated() { this.draw() },
  draw() {
    const data = JSON.parse(this.el.dataset.results)
    const textColor = getComputedStyle(this.el).color
    this.chart.setOption({
      animation: false,
      tooltip: { trigger: "item", renderMode: "richText", formatter: "{b}: {c} ({d}%)" },
      legend: { orient: "vertical", right: 0, top: "center", type: "plain", textStyle: { color: textColor, fontSize: 11 } },
      series: [{
        type: "pie", radius: ["48%", "78%"], center: ["25%", "50%"],
        label: { show: false },
        data: data.map(item => ({ ...item, itemStyle: { color: colors[item.name] || "#94a3b8" } })),
      }],
    }, true)
  },
  destroyed() {
    this.resizeObserver.disconnect()
    this.chart.dispose()
  },
}

import * as echarts from "../vendor/echarts.min.js"

const colors = {
  Claimed: "#22c55e", Ignored: "#f59e0b", Declined: "#ef4444",
  Undelivered: "#a855f7", Open: "#3b82f6", Superseded: "#94a3b8",
  Expired: "#64748b", "N a": "#14b8a6",
  Pass: "#22c55e", Fail: "#ef4444", Partial: "#f59e0b",
  Message: "#3b82f6", Restart: "#a855f7", "Work offer": "#22c55e", Analysis: "#14b8a6",
  "Check in": "#f59e0b", "Turn end": "#64748b", "Harness restart": "#ef4444",
  "Failed turn": "#dc2626", Promotion: "#8b5cf6", Problems: "#0ea5e9",
  "Team free": "#84cc16", "Offer notice": "#eab308", Unblocked: "#06b6d4",
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

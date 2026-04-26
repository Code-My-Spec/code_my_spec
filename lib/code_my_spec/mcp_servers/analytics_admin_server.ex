defmodule CodeMySpec.McpServers.AnalyticsAdminServer do
  @moduledoc false
  use Anubis.Server,
    name: "analytics-admin-server",
    version: "1.0.0",
    capabilities: [:tools]

  # Tool components - Custom Dimensions
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.ListCustomDimensions)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.GetCustomDimension)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.CreateCustomDimension)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.UpdateCustomDimension)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.ArchiveCustomDimension)

  # Tool components - Custom Metrics
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.ListCustomMetrics)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.CreateCustomMetric)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.GetCustomMetric)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.UpdateCustomMetric)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.ArchiveCustomMetric)

  # Tool components - Key Events
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.ListKeyEvents)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.CreateKeyEvent)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.UpdateKeyEvent)
  component(CodeMySpec.McpServers.AnalyticsAdmin.Tools.DeleteKeyEvent)
end

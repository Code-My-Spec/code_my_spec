defmodule CodeMySpec.McpServers.IssuesServer do
  @moduledoc false

  use Hermes.Server,
    name: "issues-server",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
end

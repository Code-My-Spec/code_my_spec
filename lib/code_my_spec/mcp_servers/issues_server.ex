defmodule CodeMySpec.McpServers.IssuesServer do
  @moduledoc false

  use Anubis.Server,
    name: "issues-server",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
end

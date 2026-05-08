defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.Environments,
      CodeMySpec.McpServers,
      CodeMySpec.Repo,
      CodeMySpecWeb,
      CodeMySpecLocalWeb
    ]
end

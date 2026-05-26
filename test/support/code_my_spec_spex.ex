defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Environments,
      CodeMySpec.McpServers,
      CodeMySpecSpex.Fixtures,
      CodeMySpecWeb,
      CodeMySpecLocalWeb
    ]
end

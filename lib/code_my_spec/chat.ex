defmodule CodeMySpec.Chat do
  @moduledoc """
  In-app chat: turn running, tool dispatch, and the provider abstraction.

  No functions of its own — this file exists so `CodeMySpec.Chat.*` has a
  boundary to be classified under (`Runner`, `Provider`, `ToolRegistry`,
  `McpToolRegistry`), the same shape as `CodeMySpec.McpServers`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Conversations,
      CodeMySpec.McpServers,
      CodeMySpec.Projects,
      CodeMySpec.Stories,
      CodeMySpec.Users
    ],
    exports: :all
end

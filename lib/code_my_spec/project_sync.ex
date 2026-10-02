defmodule CodeMySpec.ProjectSync do
  @moduledoc """
  Single-path file sync and its PubSub topic.

  No functions of its own — this file exists so `CodeMySpec.ProjectSync.Sync`
  has a boundary to be classified under, the same shape as
  `CodeMySpec.McpServers`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Files,
      CodeMySpec.Users.Scope
    ],
    exports: :all
end

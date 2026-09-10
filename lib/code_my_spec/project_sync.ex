defmodule CodeMySpec.ProjectSync do
  @moduledoc """
  Watches a project's working copies on disk and keeps its file/dependency
  rows current.

  No functions of its own — this file exists so `CodeMySpec.ProjectSync.*`
  has a boundary to be classified under (`Sync`, `FileWatcherServer`), the
  same shape as `CodeMySpec.McpServers`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Dependencies,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Users
    ],
    exports: :all
end

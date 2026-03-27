defmodule CodeMySpec.AgentTasks.Init.CliConfig do
  @moduledoc """
  Init step: project linked in local database with local_path set.
  """

  import Ecto.Query

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()

    query = from p in CodeMySpec.Projects.Project, where: p.local_path == ^dir

    case CodeMySpec.Repo.one(query) do
      %{id: _} -> {:ok, :valid}
      nil -> {:ok, :invalid, "No project linked to this directory"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Link Project

    1. Use the `list_projects` tool to see available projects
    2. Use `init_project` with the project_id to link this directory

    Then add to `.gitignore`:
    ```
    .code_my_spec/internal/
    /diagnostics.jsonl
    ```
    """}
  end
end

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

    Use the `init_project` tool to link this directory to a CodeMySpec project.
    Pass the `project_id` for the project you want to link.

    Then add to `.gitignore`:
    ```
    .code_my_spec/internal/
    /diagnostics.jsonl
    ```
    """}
  end
end

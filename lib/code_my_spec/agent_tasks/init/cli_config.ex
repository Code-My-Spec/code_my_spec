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

    1. List available projects:
    ```bash
    curl -s http://localhost:4003/api/bootstrap/projects
    ```

    2. Ask the user which project, then init:
    ```bash
    curl -s -X POST http://localhost:4003/api/bootstrap/init \\
      -H "Content-Type: application/json" \\
      -H "X-Working-Dir: $(pwd)" \\
      -d '{"project_id": "<PROJECT_ID>"}'
    ```

    3. Add to `.gitignore`:
    ```
    .code_my_spec/internal/
    /diagnostics.jsonl
    ```
    """}
  end
end

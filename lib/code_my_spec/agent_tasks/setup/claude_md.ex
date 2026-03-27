defmodule CodeMySpec.AgentTasks.Setup.ClaudeMd do
  @moduledoc """
  Setup step: CLAUDE.md with managed section exists at project root.
  """

  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment

    case Environments.read_file(env, "CLAUDE.md") do
      {:ok, content} ->
        if String.contains?(content, "<!-- code_my_spec:start -->"),
          do: {:ok, :valid},
          else: {:ok, :invalid, "`CLAUDE.md` exists but missing CodeMySpec managed section"}

      _ ->
        {:ok, :invalid, "CLAUDE.md not found"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install CLAUDE.md

    ```bash
    curl -s -X POST http://localhost:4003/api/bootstrap/install-claude-md \\
      -H "X-Working-Dir: $(pwd)"
    ```
    """}
  end
end

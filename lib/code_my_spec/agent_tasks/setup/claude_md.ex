defmodule CodeMySpec.AgentTasks.Setup.ClaudeMd do
  @moduledoc """
  Setup step: CLAUDE.md with managed section exists at project root.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()
    path = Path.join(dir, "CLAUDE.md")

    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, "<!-- code_my_spec:start -->"),
          do: {:ok, :valid},
          else: {:ok, :invalid, "`#{path}` exists but missing CodeMySpec managed section"}

      _ ->
        {:ok, :invalid, "CLAUDE.md not found at `#{path}`"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install CLAUDE.md

    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-claude-md \\
      -H "X-Working-Dir: $(pwd)"
    ```
    """}
  end
end

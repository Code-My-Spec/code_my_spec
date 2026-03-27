defmodule CodeMySpec.AgentTasks.Setup.AgentsMd do
  @moduledoc """
  Setup step: AGENTS.md generated in .code_my_spec/.
  """

  def evaluate(scope, _task) do
    dir = scope.cwd || File.cwd!()
    path = Path.join([dir, CodeMySpec.Paths.base_dir(), "AGENTS.md"])

    if File.exists?(path),
      do: {:ok, :valid},
      else: {:ok, :invalid, "AGENTS.md not found at `#{path}`"}
  end

  def command(_scope, _task) do
    {:ok, """
    # Generate AGENTS.md

    ```bash
    curl -s -X POST http://localhost:4003/api/bootstrap/install-agents-md \\
      -H "X-Working-Dir: $(pwd)"
    ```
    """}
  end
end

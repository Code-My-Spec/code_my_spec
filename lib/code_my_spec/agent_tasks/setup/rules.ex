defmodule CodeMySpec.AgentTasks.Setup.Rules do
  @moduledoc """
  Setup step: default rules installed in .code_my_spec/rules/.
  """

  def evaluate(scope, _session, _opts \\ []) do
    dir = scope.cwd || File.cwd!()
    rules_path = Path.join(dir, CodeMySpec.Paths.rules_dir())

    if File.dir?(rules_path) do
      files = File.ls!(rules_path) |> Enum.filter(&String.ends_with?(&1, ".md"))

      if files != [],
        do: {:ok, :valid},
        else: {:ok, :invalid, "No rule files found in `#{rules_path}`"}
    else
      {:ok, :invalid, "Rules directory not found at `#{rules_path}`"}
    end
  end

  def command(_scope, _session, _opts \\ []) do
    {:ok, """
    # Install Default Rules

    ```bash
    curl -s -X POST http://localhost:4002/api/bootstrap/install-rules \\
      -H "X-Working-Dir: $(pwd)"
    ```
    """}
  end
end

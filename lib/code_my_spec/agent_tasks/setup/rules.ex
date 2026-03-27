defmodule CodeMySpec.AgentTasks.Setup.Rules do
  @moduledoc """
  Setup step: default rules installed in .code_my_spec/rules/.
  """

  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment
    rules_path = CodeMySpec.Paths.rules_dir()

    case Environments.list_directory(env, rules_path) do
      {:ok, files} ->
        md_files = Enum.filter(files, &String.ends_with?(&1, ".md"))

        if md_files != [],
          do: {:ok, :valid},
          else: {:ok, :invalid, "No rule files found in `#{rules_path}`"}

      _ ->
        {:ok, :invalid, "Rules directory not found at `#{rules_path}`"}
    end
  end

  def command(_scope, _task) do
    {:ok, """
    # Install Default Rules

    Use the `install_rules` tool to copy default rule files into `.code_my_spec/rules/`.
    """}
  end
end

defmodule CodeMySpec.AgentTasks.Setup.Rules do
  @moduledoc """
  Setup step: default rules installed in .code_my_spec/rules/.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    rules_path = CodeMySpec.Paths.rules_dir()

    case Context.files_with_role(ctx, :rule) do
      [] -> {:invalid, "No rule files found in `#{rules_path}`"}
      _ -> :valid
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok, """
    # Install Default Rules

    Use the `install_rules` tool to copy default rule files into `.code_my_spec/rules/`.
    """}
  end
end

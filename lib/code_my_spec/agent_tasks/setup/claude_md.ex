defmodule CodeMySpec.AgentTasks.Setup.ClaudeMd do
  @moduledoc """
  Setup step: CLAUDE.md with managed section exists at project root.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    case Context.error(ctx, "CLAUDE.md", :managed_section, "CLAUDE.md not found") do
      nil -> :valid
      msg -> {:invalid, msg}
    end
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok, """
    # Install CLAUDE.md

    Use the `install_claude_md` tool to create or update the managed section in CLAUDE.md.
    """}
  end
end

defmodule CodeMySpec.AgentTasks.Setup.AgentsMd do
  @moduledoc """
  Setup step: AGENTS.md generated in .code_my_spec/.
  """

  alias CodeMySpec.AgentTasks.Setup.Context

  def check(%Context{} = ctx) do
    path = Path.join(CodeMySpec.Paths.base_dir(), "AGENTS.md")

    if Context.file(ctx, path),
      do: :valid,
      else: {:invalid, "AGENTS.md not found at `#{path}`"}
  end

  def evaluate(scope, _task) do
    scope |> Context.load() |> check() |> wrap()
  end

  defp wrap(:valid), do: {:ok, :valid}
  defp wrap({:invalid, reason}), do: {:ok, :invalid, reason}

  def command(_scope, _task) do
    {:ok, """
    # Generate AGENTS.md

    Use the `install_agents_md` tool to generate the project agent guide.
    """}
  end
end

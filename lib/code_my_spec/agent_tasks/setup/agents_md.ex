defmodule CodeMySpec.AgentTasks.Setup.AgentsMd do
  @moduledoc """
  Setup step: AGENTS.md generated in .code_my_spec/.
  """

  alias CodeMySpec.Environments

  def evaluate(scope, _task) do
    env = scope.environment
    path = Path.join(CodeMySpec.Paths.base_dir(), "AGENTS.md")

    if Environments.file_exists?(env, path),
      do: {:ok, :valid},
      else: {:ok, :invalid, "AGENTS.md not found at `#{path}`"}
  end

  def command(_scope, _task) do
    {:ok, """
    # Generate AGENTS.md

    Use the `install_agents_md` tool to generate the project agent guide.
    """}
  end
end

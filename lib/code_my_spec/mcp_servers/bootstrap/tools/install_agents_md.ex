defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd do
  @moduledoc """
  Generate and write .code_my_spec/AGENTS.md for the project.

  Detects the app name from mix.exs and writes a project-specific agent guide.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    case ProjectSetup.install_agents_md(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/AGENTS.md"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to write AGENTS.md: #{inspect(reason)}"), frame}
    end
  end
end

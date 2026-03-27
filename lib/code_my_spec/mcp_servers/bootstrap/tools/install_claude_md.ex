defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd do
  @moduledoc """
  Create or update the managed section in CLAUDE.md at the project root.

  Preserves existing content — only the managed section (between HTML comment
  markers) is created or updated. Idempotent.
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

    case ProjectSetup.install_claude_md(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success("CLAUDE.md"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install CLAUDE.md: #{inspect(reason)}"), frame}
    end
  end
end

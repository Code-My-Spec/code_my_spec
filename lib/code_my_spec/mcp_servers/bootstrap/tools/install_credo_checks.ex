defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks do
  @moduledoc """
  Install Credo custom checks directory structure.

  Creates framework/ and local/ subdirectories under .code_my_spec/credo_checks/.
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

    case ProjectSetup.install_credo_checks(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/credo_checks/"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install credo checks: #{inspect(reason)}"), frame}
    end
  end
end

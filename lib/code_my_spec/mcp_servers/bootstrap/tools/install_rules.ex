defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallRules do
  @moduledoc """
  Copy default rule files into the project's .code_my_spec/rules/ directory.

  Only copies files that don't already exist, preserving user customizations.
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

    case ProjectSetup.install_rules(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/rules/"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install rules: #{inspect(reason)}"), frame}
    end
  end
end

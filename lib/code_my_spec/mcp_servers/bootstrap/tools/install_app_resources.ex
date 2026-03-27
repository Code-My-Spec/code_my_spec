defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallAppResources do
  @moduledoc """
  Copy framework knowledge and tools into the project's .code_my_spec/ directory.

  Copies files from priv/knowledge → .code_my_spec/framework/ and
  priv/tools → .code_my_spec/tools/.
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

    case ProjectSetup.install_app_resources(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/framework/, .code_my_spec/tools/"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install resources: #{inspect(reason)}"), frame}
    end
  end
end

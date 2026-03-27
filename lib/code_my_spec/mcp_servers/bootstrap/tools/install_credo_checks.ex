defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks do
  @moduledoc """
  Install Credo custom checks directory structure.

  Creates framework/ and local/ subdirectories under .code_my_spec/credo_checks/.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    framework_dir = Path.join(working_dir, CodeMySpec.Paths.credo_checks_framework_dir())
    local_dir = Path.join(working_dir, CodeMySpec.Paths.credo_checks_local_dir())

    with :ok <- File.mkdir_p(framework_dir),
         :ok <- File.mkdir_p(local_dir) do
      {:reply, BootstrapMapper.install_success(".code_my_spec/credo_checks/"), frame}
    else
      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install credo checks: #{inspect(reason)}"), frame}
    end
  end
end

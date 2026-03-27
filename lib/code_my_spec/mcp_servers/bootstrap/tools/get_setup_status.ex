defmodule CodeMySpec.McpServers.Bootstrap.Tools.GetSetupStatus do
  @moduledoc """
  Check the status of post-init project setup steps and get the setup prompt.

  Returns the full setup prompt with checklist of steps like project compilation,
  dependency installation, config setup, and resource installation.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.ProjectSetup
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Users.Scope

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)
    env = Environment.new(:local, working_dir)
    scope = %Scope{environment: env}

    {:ok, prompt} = ProjectSetup.command(scope, %{})
    {:reply, BootstrapMapper.status_response(prompt, %{status: :ok}), frame}
  end
end

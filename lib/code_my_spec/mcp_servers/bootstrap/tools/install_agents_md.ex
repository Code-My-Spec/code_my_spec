defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd do
  @moduledoc """
  Generate and write .code_my_spec/AGENTS.md for the project.

  Detects the app name from mix.exs and writes a project-specific agent guide.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Bootstrap.{BootstrapMapper, Content}
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    case install(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/AGENTS.md"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to write AGENTS.md: #{inspect(reason)}"), frame}
    end
  end

  defp install(working_dir) do
    app_name = Content.extract_app_name(Path.join(working_dir, "mix.exs"))
    content = Content.agents_md_content(app_name)
    agents_path = Path.join([working_dir, CodeMySpec.Paths.base_dir(), "AGENTS.md"])

    with :ok <- agents_path |> Path.dirname() |> File.mkdir_p() do
      File.write(agents_path, content)
    end
  end
end

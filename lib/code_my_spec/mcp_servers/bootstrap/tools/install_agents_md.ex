defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd do
  @moduledoc """
  Generate and write .code_my_spec/AGENTS.md for the project.

  Detects the app name from mix.exs and writes a project-specific agent guide.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.{BootstrapMapper, Content}
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    env = Validators.mcp_environment(frame)

    case install(env) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/AGENTS.md"), frame}

      {:error, :no_mix_exs} ->
        {:reply,
         BootstrapMapper.error(
           "mix.exs not found in #{env.cwd}. This doesn't look like an Elixir project — CodeMySpec currently only supports Phoenix/Elixir. Run this tool from the project root."
         ), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to write AGENTS.md: #{inspect(reason)}"), frame}
    end
  end

  defp install(env) do
    with {:ok, mix_exs} <- read_mix_exs(env),
         app_name <- Content.extract_app_name_from_source(mix_exs),
         content <- Content.agents_md_content(app_name),
         agents_path <- Path.join(CodeMySpec.Paths.base_dir(), "AGENTS.md") do
      Environments.write_file(env, agents_path, content)
    end
  end

  defp read_mix_exs(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :no_mix_exs}
      {:error, reason} -> {:error, reason}
    end
  end
end

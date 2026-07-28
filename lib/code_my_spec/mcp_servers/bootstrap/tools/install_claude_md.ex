defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd do
  @moduledoc """
  Create or update the managed section in CLAUDE.md at the project root.

  Preserves existing content — only the managed section (between HTML comment
  markers) is created or updated. Idempotent.
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
        {:reply, BootstrapMapper.install_success("CLAUDE.md"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install CLAUDE.md: #{inspect(reason)}"), frame}
    end
  end

  @doc """
  Create or refresh the managed section in `CLAUDE.md`. Public because
  `init_project` runs it directly — see
  `CodeMySpec.McpServers.Bootstrap.Installers`.
  """
  def install(env) do
    app_name = extract_app_name(env)
    managed_section = Content.claude_md_content(app_name)
    start_marker = Content.claude_md_start_marker()

    case Environments.read_file(env, "CLAUDE.md") do
      {:ok, existing} ->
        if String.contains?(existing, start_marker) do
          updated = replace_managed_section(existing, managed_section)
          Environments.write_file(env, "CLAUDE.md", updated)
        else
          Environments.write_file(env, "CLAUDE.md", existing <> "\n" <> managed_section)
        end

      {:error, :enoent} ->
        Environments.write_file(env, "CLAUDE.md", managed_section)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_app_name(env) do
    case Environments.read_file(env, "mix.exs") do
      {:ok, content} -> Content.extract_app_name_from_source(content)
      _ -> nil
    end
  end

  defp replace_managed_section(content, managed_section) do
    start_marker = Content.claude_md_start_marker()
    end_marker = Content.claude_md_end_marker()
    pattern = ~r/#{Regex.escape(start_marker)}.*#{Regex.escape(end_marker)}/s
    String.replace(content, pattern, String.trim_trailing(managed_section))
  end
end

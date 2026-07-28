defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallRules do
  @moduledoc """
  Copy default rule files into the project's .code_my_spec/rules/ directory.

  Only copies files that don't already exist, preserving user customizations.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    env = Validators.mcp_environment(frame)

    case install(env) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/rules/"), frame}

      {:error, {:source_dir, :enoent}} ->
        {:reply, BootstrapMapper.error(stale_server_message("priv/rules")), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install rules: #{inspect(reason)}"), frame}
    end
  end

  # `Application.app_dir/2` resolves against the RUNNING release's priv — a
  # missing source dir almost always means the cms binary was updated on disk
  # while an older BEAM kept serving (its extracted priv no longer matches).
  # A bare `:enoent` cost a real user a debugging session; say the fix.
  defp stale_server_message(dir) do
    "The running cms server can't find its #{dir} directory. This usually means " <>
      "the server was updated while the old process kept running — restart it " <>
      "(macOS: `brew services restart codemyspec`; Windows: restart the CodeMySpec " <>
      "service) and retry."
  end

  @doc """
  Install the default rules. Public because `init_project` runs it directly:
  a fresh project should not need an agent turn to get its own rule files.

  Source files ship with the harness package (`priv/rules/`) and are read
  straight from disk; only the destination is routed through the environment
  so specs can install into an in-memory project.
  """
  def install(env) do
    source_dir = Application.app_dir(:code_my_spec, "priv/rules")
    target_dir = CodeMySpec.Paths.rules_dir()

    with :ok <- Environments.ensure_dir(env, target_dir) do
      case File.ls(source_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(fn file ->
            Environments.file_exists?(env, Path.join(target_dir, file))
          end)
          |> copy_rules(env, source_dir, target_dir)

        {:error, reason} ->
          {:error, {:source_dir, reason}}
      end
    end
  end

  defp copy_rules(files, env, source_dir, target_dir) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      with {:ok, content} <- File.read(Path.join(source_dir, file)),
           :ok <- Environments.write_file(env, Path.join(target_dir, file), content) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end

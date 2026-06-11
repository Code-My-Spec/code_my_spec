defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks do
  @moduledoc """
  Install Credo custom checks into the project.

  Creates `.code_my_spec/credo_checks/{framework,local}/` and copies the
  framework checks shipped in the harness's `priv/credo_checks/` into
  the project's `framework/` directory. The `local/` directory is left
  empty for project-specific checks.
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

    framework_dir = CodeMySpec.Paths.credo_checks_framework_dir()
    local_dir = CodeMySpec.Paths.credo_checks_local_dir()
    source_dir = Application.app_dir(:code_my_spec, "priv/credo_checks")

    with :ok <- Environments.ensure_dir(env, framework_dir),
         :ok <- Environments.ensure_dir(env, local_dir),
         :ok <- copy_framework_files(env, source_dir, framework_dir) do
      {:reply, BootstrapMapper.install_success(".code_my_spec/credo_checks/"), frame}
    else
      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install credo checks: #{inspect(reason)}"), frame}
    end
  end

  # Idempotent: never overwrites an existing destination file. Once a
  # framework check is installed into a project, the project owns it —
  # subsequent re-runs leave it untouched even if the harness ships a
  # newer version. Updating the framework default is an explicit
  # opt-in (delete the file, then re-install).
  #
  # Source files ship with the harness package (`priv/credo_checks/`) and
  # are read straight from disk; only the destination is routed through the
  # environment so specs can install into an in-memory project.
  defp copy_framework_files(env, source_dir, framework_dir) do
    case File.ls(source_dir) do
      {:ok, entries} -> reduce_copies(env, entries, source_dir, framework_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reduce_copies(env, entries, source_dir, framework_dir) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      copy_entry(env, Path.join(source_dir, entry), Path.join(framework_dir, entry))
    end)
  end

  defp copy_entry(env, src, dst) do
    cond do
      not File.regular?(src) -> {:cont, :ok}
      Environments.file_exists?(env, dst) -> {:cont, :ok}
      true -> do_copy(env, src, dst)
    end
  end

  defp do_copy(env, src, dst) do
    with {:ok, content} <- File.read(src),
         :ok <- Environments.write_file(env, dst, content) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end
end

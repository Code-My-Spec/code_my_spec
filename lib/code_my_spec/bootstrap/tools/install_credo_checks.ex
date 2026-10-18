defmodule CodeMySpec.Bootstrap.Tools.InstallCredoChecks do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.Bootstrap.Tools.Responses, as: BootstrapMapper

  @impl true
  def name, do: "install_credo_checks"

  @impl true
  def description do
    """
    Install Credo custom checks into the project.

    Creates `.code_my_spec/credo_checks/{framework,local}/` and copies the
    framework checks shipped in the harness's `priv/credo_checks/` into
    the project's `framework/` directory. The `local/` directory is left
    empty for project-specific checks.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    env = CodeMySpec.WorkingCopies.tool_environment(context[:scope], context[:working_dir])

    case install(env) do
      :ok ->
        BootstrapMapper.install_success(".code_my_spec/credo_checks/")

      {:error, {:source_dir, :enoent}} ->
        BootstrapMapper.error(stale_server_message())

      {:error, :no_working_copy} ->
        BootstrapMapper.error(CodeMySpec.Tools.no_working_copy_message("install_credo_checks"))

      {:error, reason} ->
        BootstrapMapper.error("Failed to install credo checks: #{inspect(reason)}")
    end
  end

  # `Application.app_dir/2` resolves against the RUNNING release's priv — a
  # missing source dir almost always means the cms binary was updated on disk
  # while an older BEAM kept serving. A bare `:enoent` cost a real user a
  # debugging session; say the fix.
  defp stale_server_message do
    "The running cms server can't find its priv/credo_checks directory. This " <>
      "usually means the server was updated while the old process kept running — " <>
      "restart it (macOS: `brew services restart codemyspec`; Windows: restart " <>
      "the CodeMySpec service) and retry."
  end

  @doc """
  Install the framework Credo checks. Public because `init_project` runs it
  directly — see `CodeMySpec.Bootstrap.Tools.Installers`.
  """
  # No working copy here. Refusing is the whole point: the previous behaviour
  # was to root a `:local` environment at the server's own checkout and write
  # there, reporting success. See `WorkingCopies.tool_environment/1`.
  def install(nil), do: {:error, :no_working_copy}

  def install(env) do
    framework_dir = CodeMySpec.Paths.credo_checks_framework_dir()
    local_dir = CodeMySpec.Paths.credo_checks_local_dir()
    source_dir = Application.app_dir(:code_my_spec, "priv/credo_checks")

    with :ok <- Environments.ensure_dir(env, framework_dir),
         :ok <- Environments.ensure_dir(env, local_dir) do
      copy_framework_files(env, source_dir, framework_dir)
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
      {:error, reason} -> {:error, {:source_dir, reason}}
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

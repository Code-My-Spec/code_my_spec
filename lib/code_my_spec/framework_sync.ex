defmodule CodeMySpec.FrameworkSync do
  @moduledoc """
  Copies framework knowledge and tools from the app's priv/ into a
  project's `.code_my_spec/` directory.

  Ensures the project always has the latest framework docs and tool scripts
  matching the installed app version. Symlinks aren't used because Claude Code
  can't follow them.

  No-ops gracefully when there's no `.code_my_spec/` directory.
  """

  require Logger

  alias CodeMySpec.Paths

  @copy_dirs [
    {"priv/knowledge", Paths.framework_dir()},
    {"priv/tools", Paths.tools_dir()},
    {"priv/credo_checks", Paths.credo_checks_framework_dir()}
  ]

  @doc """
  Sync framework and tools into the project at `cwd`.

  Skips if no `.code_my_spec/` directory exists in `cwd`.
  """
  def sync(cwd) when is_binary(cwd) do
    base_dir = Path.join(cwd, Paths.base_dir())

    if File.dir?(base_dir) do
      Enum.each(@copy_dirs, fn {priv_subdir, relative_target} ->
        source = Application.app_dir(:code_my_spec, priv_subdir)
        target = Path.join(cwd, relative_target)
        copy_dir(source, target)
      end)

      Logger.debug("[FrameworkSync] Synced framework and tools to #{base_dir}")
      :ok
    else
      Logger.debug("[FrameworkSync] No #{base_dir} directory, skipping")
      :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_dir(source, target) do
    if File.exists?(target) or symlink?(target) do
      File.rm_rf!(target)
    end

    File.mkdir_p!(Path.dirname(target))
    File.cp_r!(source, target)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end
end

defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallAppResources do
  @moduledoc """
  Copy framework knowledge and tools into the project's .code_my_spec/ directory.

  Copies files from priv/knowledge → .code_my_spec/framework/ and
  priv/tools → .code_my_spec/tools/.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  @copy_dirs [
    {"priv/knowledge", :framework_dir},
    {"priv/tools", :tools_dir},
    {"priv/credo_checks", :credo_checks_framework_dir}
  ]

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    case install(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/framework/, .code_my_spec/tools/"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install resources: #{inspect(reason)}"), frame}
    end
  end

  defp install(working_dir) do
    Enum.reduce_while(@copy_dirs, :ok, fn {priv_subdir, path_fn}, :ok ->
      source = Application.app_dir(:code_my_spec, priv_subdir)
      target = Path.join(working_dir, apply(CodeMySpec.Paths, path_fn, []))

      case copy_dir(source, target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_dir(source, target) do
    with :ok <- target |> Path.dirname() |> File.mkdir_p() do
      if File.exists?(target) or symlink?(target), do: File.rm_rf(target)

      case File.cp_r(source, target) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end
end

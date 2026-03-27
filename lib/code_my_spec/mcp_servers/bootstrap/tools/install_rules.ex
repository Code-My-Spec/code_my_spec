defmodule CodeMySpec.McpServers.Bootstrap.Tools.InstallRules do
  @moduledoc """
  Copy default rule files into the project's .code_my_spec/rules/ directory.

  Only copies files that don't already exist, preserving user customizations.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)

    case install(working_dir) do
      :ok ->
        {:reply, BootstrapMapper.install_success(".code_my_spec/rules/"), frame}

      {:error, reason} ->
        {:reply, BootstrapMapper.error("Failed to install rules: #{inspect(reason)}"), frame}
    end
  end

  defp install(working_dir) do
    source_dir = Application.app_dir(:code_my_spec, "priv/rules")
    target_dir = Path.join(working_dir, CodeMySpec.Paths.rules_dir())

    with :ok <- File.mkdir_p(target_dir) do
      case File.ls(source_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.reject(fn file -> File.exists?(Path.join(target_dir, file)) end)
          |> Enum.each(fn file ->
            File.cp!(Path.join(source_dir, file), Path.join(target_dir, file))
          end)

          :ok

        {:error, reason} ->
          {:error, {:source_dir, reason}}
      end
    end
  end
end

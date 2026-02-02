defmodule CodeMySpec.McpServers.Architecture.Tools.DeleteSpec do
  @moduledoc "Deletes a component spec file and removes from database"

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :module_name, :string, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir(frame)),
         {:ok, component} <- find_component(scope, params.module_name),
         {:ok, spec_path} <- build_spec_path(params.module_name),
         :ok <- delete_spec_file(env, spec_path),
         {:ok, _deleted} <- delete_from_database(scope, component) do
      Environments.destroy(env)

      response = %{
        success: true,
        message: "Spec deleted successfully",
        module_name: params.module_name,
        spec_path: spec_path
      }

      {:reply, Hermes.Server.Response.tool() |> Hermes.Server.Response.json(response), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp find_component(scope, module_name) do
    case Components.get_component_by_module_name(scope, module_name) do
      nil -> {:error, "Component not found: #{module_name}"}
      component -> {:ok, component}
    end
  end

  defp build_spec_path(module_name) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    spec_path = Path.join(["docs/spec" | path_parts]) <> ".spec.md"
    {:ok, spec_path}
  end

  defp delete_spec_file(env, spec_path) do
    case Environments.delete_file(env, spec_path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to delete spec file: #{inspect(reason)}"}
    end
  end

  defp delete_from_database(scope, component) do
    Components.delete_component(scope, component)
  end
end

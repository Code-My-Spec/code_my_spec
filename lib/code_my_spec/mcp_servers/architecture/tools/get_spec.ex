defmodule CodeMySpec.McpServers.Architecture.Tools.GetSpec do
  @moduledoc """
  Retrieves a component spec with metadata and content.

  Returns component info from the database plus spec file content if it exists.
  If no spec file exists yet, returns component info with a note about the missing file.
  Use `create_spec` to create a spec file for a component.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :module_name, :string
    field :component_id, :string
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, component} <- find_component(scope, params),
         {:ok, spec_path} <- build_spec_path(component.module_name) do
      spec_result = read_spec_file(env, spec_path)
      Environments.destroy(env)

      case spec_result do
        {:ok, spec_content} ->
          {:reply, ArchitectureMapper.spec_response(component, spec_path, spec_content), frame}

        {:error, :not_found} ->
          {:reply, ArchitectureMapper.spec_not_found_response(component, spec_path), frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp find_component(scope, params) do
    cond do
      Map.has_key?(params, :module_name) and not is_nil(params.module_name) ->
        case Components.get_component_by_module_name(scope, params.module_name) do
          nil -> {:error, "Component not found: #{params.module_name}"}
          component -> {:ok, load_dependencies(component, scope)}
        end

      Map.has_key?(params, :component_id) and not is_nil(params.component_id) ->
        case ComponentRepository.get_component_with_dependencies(scope, params.component_id) do
          nil -> {:error, "Component not found with ID: #{params.component_id}"}
          component -> {:ok, component}
        end

      true ->
        {:error, "Either module_name or component_id must be provided"}
    end
  end

  defp load_dependencies(component, scope) do
    # If we looked up by module_name, dependencies might not be loaded
    # Get the full version with dependencies
    ComponentRepository.get_component_with_dependencies(scope, component.id) || component
  end

  defp build_spec_path(module_name) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    spec_path = Path.join(["docs/spec" | path_parts]) <> ".spec.md"
    {:ok, spec_path}
  end

  defp read_spec_file(env, spec_path) do
    case Environments.read_file(env, spec_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end
end

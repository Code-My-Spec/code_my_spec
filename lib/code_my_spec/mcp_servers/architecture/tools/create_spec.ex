defmodule CodeMySpec.McpServers.Architecture.Tools.CreateSpec do
  @moduledoc "Creates a new component spec file and syncs to database"

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :module_name, :string, required: true
    field :type, :string, required: true
    field :description, :string
    field :dependencies, {:list, :string}, default: []
    field :story_ids, {:list, :integer}, default: []
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, spec_path} <- write_spec_file(env, params),
         {:ok, component} <- sync_to_database(scope, params) do
      Environments.destroy(env)
      link_stories(scope, component, params[:story_ids] || [])
      {:reply, ArchitectureMapper.spec_created(component, spec_path), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp link_stories(_scope, _component, []), do: :ok

  defp link_stories(scope, component, story_ids) do
    Enum.each(story_ids, fn story_id ->
      case Stories.get_story(scope, story_id) do
        nil -> :ok
        story -> Stories.set_story_component(scope, story, component.id)
      end
    end)
  end

  defp write_spec_file(env, %{module_name: module_name} = params) do
    spec_path = build_spec_path(module_name)
    spec_content = generate_spec_template(params)

    case Environments.write_file(env, spec_path, spec_content) do
      :ok -> {:ok, spec_path}
      {:error, reason} -> {:error, "Failed to write spec file: #{inspect(reason)}"}
    end
  end

  defp sync_to_database(scope, params) do
    component_attrs = %{
      module_name: params.module_name,
      type: params.type,
      description: params[:description],
      name: derive_name_from_module(params.module_name)
    }

    case Components.upsert_component(scope, component_attrs) do
      %{id: _} = component -> {:ok, component}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp build_spec_path(module_name) do
    # Convert module name to path: CodeMySpec.Foo.Bar -> docs/spec/code_my_spec/foo/bar.spec.md
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["docs/spec" | path_parts]) <> ".spec.md"
  end

  defp derive_name_from_module(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp generate_spec_template(params) do
    """
    # #{params.module_name}

    #{params[:description] || "No description provided"}

    ## Type

    #{params.type}

    ## Dependencies

    #{format_dependencies(params[:dependencies] || [])}

    ## Functions

    """
  end

  defp format_dependencies([]), do: "- None"

  defp format_dependencies(deps) do
    deps
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end
end

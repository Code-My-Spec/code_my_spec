defmodule CodeMySpec.McpServers.Architecture.Tools.UpdateSpecMetadata do
  @moduledoc "Updates spec file metadata without overwriting function/field documentation"

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :module_name, :string, required: true
    field :description, :string
    field :dependencies, {:list, :string}
    field :type, :string
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli, working_dir: Validators.mcp_working_dir()),
         {:ok, spec_path} <- find_spec_path(env, params.module_name),
         {:ok, _} <- update_spec_file(env, spec_path, params),
         {:ok, component} <- sync_to_database(scope, params) do
      Environments.destroy(env)
      {:reply, ArchitectureMapper.spec_updated(component, spec_path), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp find_spec_path(env, module_name) do
    spec_path = build_spec_path(module_name)

    if Environments.file_exists?(env, spec_path) do
      {:ok, spec_path}
    else
      {:error, "Spec file not found: #{spec_path}"}
    end
  end

  defp update_spec_file(env, spec_path, params) do
    case Environments.read_file(env, spec_path) do
      {:ok, content} ->
        updated_content = update_metadata_sections(content, params)

        case Environments.write_file(env, spec_path, updated_content) do
          :ok -> {:ok, spec_path}
          {:error, reason} -> {:error, "Failed to write spec file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read spec file: #{inspect(reason)}"}
    end
  end

  defp update_metadata_sections(content, params) do
    lines = String.split(content, "\n")

    # Find the sections - keep as lists until final join
    {header_lines, rest} = extract_until_section(lines, "## ")
    {type_lines, after_type} = extract_section_lines(rest, "## Type")
    {deps_lines, remaining} = extract_section_lines(after_type, "## Dependencies")

    # Update header (title + description)
    updated_header = update_header_section(header_lines, params)

    # Update type section if provided, otherwise preserve existing
    updated_type =
      if Map.has_key?(params, :type) and not is_nil(params[:type]) do
        "## Type\n\n#{params.type}"
      else
        Enum.join(type_lines, "\n") |> String.trim()
      end

    # Update dependencies section if provided
    updated_deps =
      if Map.has_key?(params, :dependencies) and not is_nil(params[:dependencies]) do
        generate_dependencies_section(params.dependencies)
      else
        Enum.join(deps_lines, "\n") |> String.trim()
      end

    # Remaining sections as string
    remaining_str = Enum.join(remaining, "\n") |> String.trim()

    # Reconstruct the file
    [updated_header, updated_type, updated_deps, remaining_str]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp extract_until_section(lines, section_marker) do
    case Enum.find_index(lines, &String.starts_with?(&1, section_marker)) do
      nil ->
        # No section found, everything is header
        {Enum.join(lines, "\n"), []}

      index ->
        header = Enum.take(lines, index) |> Enum.join("\n") |> String.trim()
        rest = Enum.drop(lines, index)
        {header, rest}
    end
  end

  # Returns {section_lines, remaining_lines} - keeps as lists for chaining
  defp extract_section_lines(lines, section_name) do
    case Enum.find_index(lines, &String.starts_with?(&1, section_name)) do
      nil ->
        # Section not found
        {[], lines}

      start_index ->
        # Find the next ## section
        rest_lines = Enum.drop(lines, start_index + 1)

        case Enum.find_index(rest_lines, &String.starts_with?(&1, "## ")) do
          nil ->
            # This is the last section
            section = Enum.drop(lines, start_index)
            {section, []}

          next_section_index ->
            section = Enum.slice(lines, start_index, next_section_index + 1)
            remaining = Enum.drop(lines, start_index + next_section_index + 1)
            {section, remaining}
        end
    end
  end

  defp update_header_section(header_content, params) do
    lines = String.split(header_content, "\n")

    # First line should be the title (# Module.Name)
    title_line =
      case lines do
        [first | _] ->
          if String.starts_with?(first, "# ") do
            first
          else
            "# #{params.module_name}"
          end

        _ ->
          "# #{params.module_name}"
      end

    # Update description if provided
    description =
      if Map.has_key?(params, :description) and not is_nil(params[:description]) do
        params.description
      else
        # Keep existing description (everything after title line)
        lines |> Enum.drop(1) |> Enum.join("\n") |> String.trim()
      end

    "#{title_line}\n\n#{description}"
  end

  defp generate_dependencies_section(dependencies) do
    deps_list = format_dependencies(dependencies)
    "## Dependencies\n\n#{deps_list}"
  end

  defp format_dependencies([]), do: "- None"

  defp format_dependencies(deps) do
    deps
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp sync_to_database(scope, params) do
    component_attrs =
      %{
        module_name: params.module_name,
        name: derive_name_from_module(params.module_name)
      }
      |> maybe_put(:description, params[:description])
      |> maybe_put(:type, params[:type])

    case Components.upsert_component(scope, component_attrs) do
      %{id: _} = component -> {:ok, component}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp derive_name_from_module(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp build_spec_path(module_name) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["docs/spec" | path_parts]) <> ".spec.md"
  end
end

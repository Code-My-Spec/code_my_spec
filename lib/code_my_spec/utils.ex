defmodule CodeMySpec.Utils do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec, CodeMySpec.Paths, CodeMySpec.Repo],
    exports: :all

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Utils.Paths, as: UtilPaths

  def component_files(
        %Component{module_name: module_name, type: type},
        %Project{}
      ) do
    module_path = UtilPaths.module_to_path(module_name)

    # Phoenix convention: LiveViews/LiveComponents live in `live/`, controllers in `controllers/`
    source_path =
      cond do
        type in ["liveview", "liveview_component", "live_context"] -> inject_live_dir(module_path)
        type in ["controller", "json"] -> inject_controllers_dir(module_path)
        true -> module_path
      end

    base_files = %{
      design_file: Paths.design_file(module_path),
      code_file: "lib/#{source_path}.ex",
      test_file: "test/#{source_path}_test.exs",
      spec_file: Paths.spec_file(module_path)
    }

    # Add type-specific files
    cond do
      type in ["context", "coordination_context"] ->
        Map.put(base_files, :review_file, Paths.review_file(module_path))

      type == "controller" ->
        json_path = derive_json_path(source_path)
        Map.put(base_files, :json_file, "lib/#{json_path}.ex")

      true ->
        base_files
    end
  end

  def component_files(module_name) do
    module_path = UtilPaths.module_to_path(module_name)

    %{
      design_file: Paths.design_file(module_path),
      code_file: "lib/#{module_path}.ex",
      test_file: "test/#{module_path}_test.exs",
      spec_file: Paths.spec_file(module_path)
    }
  end

  # Insert `live/` after the first path segment for Phoenix LiveView convention.
  # e.g., "fuellytics_web/card_management_live" → "fuellytics_web/live/card_management_live"
  # No-op if `live` is already in the path (e.g., module is MyAppWeb.Live.SomeLive).
  defp inject_live_dir(module_path) do
    case Path.split(module_path) do
      [root | rest] ->
        if "live" in rest, do: module_path, else: Path.join([root, "live" | rest])

      _ ->
        module_path
    end
  end

  # Insert `controllers/` after the first path segment for Phoenix controller convention.
  # e.g., "my_app_web/user_controller" → "my_app_web/controllers/user_controller"
  # No-op if `controllers` is already in the path.
  defp inject_controllers_dir(module_path) do
    case Path.split(module_path) do
      [root | rest] ->
        if "controllers" in rest,
          do: module_path,
          else: Path.join([root, "controllers" | rest])

      _ ->
        module_path
    end
  end

  # Derive the JSON view path from a controller source path.
  # e.g., "my_app_web/controllers/user_controller" → "my_app_web/controllers/user_json"
  defp derive_json_path(controller_source_path) do
    String.replace_suffix(controller_source_path, "_controller", "_json")
  end

  def changeset_error_to_string(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", safe_to_string(key, value, opts))
      end)
    end)
    |> flatten_errors()
    |> Enum.map_join(", ", fn {field, message} -> "#{field}: #{message}" end)
  end

  defp safe_to_string(_key, value, _opts) do
    to_string(value)
  rescue
    Protocol.UndefinedError ->
      # Handle complex types that don't implement String.Chars (like Ecto.Enum metadata)
      # For enum types, extract the valid values if available
      case value do
        {:parameterized, {Ecto.Enum, %{mappings: mappings}}} when is_list(mappings) ->
          mappings
          |> Keyword.values()
          |> Enum.map_join(", ", &to_string/1)

        _ ->
          inspect(value)
      end
  end

  defp flatten_errors(errors, prefix \\ nil) do
    Enum.flat_map(errors, fn {field, value} ->
      field_name = if prefix, do: "#{prefix}.#{field}", else: field
      flatten_error_value(field_name, value)
    end)
  end

  defp flatten_error_value(field_name, value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item_errors, index} ->
        flatten_errors(item_errors, "#{field_name}[#{index}]")
      end)
    else
      Enum.map(value, fn msg -> {field_name, msg} end)
    end
  end

  defp flatten_error_value(field_name, value) when is_map(value) do
    flatten_errors(value, field_name)
  end

  defp flatten_error_value(field_name, value) do
    [{field_name, value}]
  end
end

defmodule CodeMySpec.Utils do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Components,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Utils.Paths, as: UtilPaths

  @doc """
  Runs `fun`, logging and returning `fallback` if it raises instead of
  taking the caller down with it.

  For a page section whose own failure must not fail the whole page — a
  gauge, a side panel's listing — where crashing the mount is worse than
  showing nothing. `label` names what crashed, so a real bug shows up in the
  log instead of reading identical to "nothing to show." Four copies of this
  shape existed with no logging at all before they were collapsed here; a
  bug behind any of them was indistinguishable from an empty result.
  """
  @spec rescued(String.t(), term(), (-> term())) :: term()
  def rescued(label, fallback, fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.warning("[#{label}] " <> Exception.message(error))
      fallback
  end

  @doc """
  `String.to_existing_atom/1`, returning `fallback` instead of raising when
  the value has no matching atom in the table.

  Converting an arbitrary string to an atom unconditionally risks unbounded
  atom-table growth if the input is ever caller- or agent-controlled —
  `to_existing_atom` already refuses that by raising for anything the VM does
  not already know. This just gives the refusal a value instead of a crash,
  for the many places that need "not a known atom" to be data.
  """
  @spec safe_to_existing_atom(String.t() | atom() | nil, term()) :: atom() | term()
  def safe_to_existing_atom(val, fallback \\ nil)
  def safe_to_existing_atom(nil, _fallback), do: nil
  def safe_to_existing_atom(val, _fallback) when is_atom(val), do: val

  def safe_to_existing_atom(val, fallback) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> fallback
  end

  @doc """
  Runs `fun`, returning `nil` instead of raising when it's given a malformed
  id — `Ecto.Query.CastError`, for a string that isn't a valid id shape (a
  non-UUID against a `:binary_id` column, non-numeric against an integer id).

  For a lookup-by-id whose caller already treats "not found" and "impossible
  id" the same way — an id arriving from outside this node (a wire param, a
  request header) is a string of unknown shape, and the schema's own type
  already answers "is this even a candidate" before the query would.
  """
  @spec safe_get((-> term())) :: term() | nil
  def safe_get(fun) when is_function(fun, 0) do
    fun.()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Atom-keys a map whose keys may already be atoms or may be strings.

  Attrs arrive atom-keyed from a caller building one inline and string-keyed
  from anywhere that round-tripped through JSON or a database row.
  `String.to_existing_atom/1` raising on a key the schema never declared
  would mean a stray param crashes the write instead of `cast/3` giving it a
  real validation error — so a single unknown key leaves the whole map
  unconverted rather than raising, and the caller's own cast rejects it.
  """
  @spec normalize_keys(map()) :: map()
  def normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end

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

defmodule CodeMySpec.Files.FileSync do
  @moduledoc """
  Synchronizes the filesystem into File records using DirWalker.

  Streams the project directory, classifies each file by path pattern,
  stats for mtime/size, and upserts File records. Returns which files changed.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Documents
  alias CodeMySpec.Files
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  @ignored_dirs ~w(deps _build .git node_modules .elixir_ls .lexical)

  @doc """
  Sync all trackable files from the filesystem into the DB.

  Returns `{:ok, %{upserted: count, removed: count, changed_paths: [path]}}`.
  """
  @spec sync(Scope.t(), keyword()) :: {:ok, map()}
  def sync(%Scope{} = scope, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, ".")
    start = System.monotonic_time(:millisecond)

    # Load ignored paths from config
    ignored_patterns = load_ignored_paths(scope)

    # Stream filesystem, classify, stat — filtering ignored
    file_entries =
      base_dir
      |> stream_files(ignored_patterns)
      |> Enum.to_list()

    scan_ms = System.monotonic_time(:millisecond) - start

    # Build path→mtime map from current DB state for change detection
    existing_files = Files.list_files(scope)
    existing_map = Map.new(existing_files, &{&1.path, &1.mtime})

    # Detect which files actually changed (new or mtime differs)
    changed_paths =
      Enum.filter(file_entries, fn entry ->
        case Map.get(existing_map, entry.path) do
          nil -> true
          db_mtime -> DateTime.compare(entry.mtime, db_mtime) == :gt
        end
      end)
      |> Enum.map(& &1.path)

    # Resolve owners for entries (component_id, story_id)
    entries_with_owners = resolve_owners(scope, file_entries)

    # Upsert all (without validation — ON CONFLICT preserves existing valid state)
    {upserted, _} = Files.upsert_files(scope, entries_with_owners)

    # Validate changed files and update their valid/validation_errors
    changed_set = MapSet.new(changed_paths)
    components = Components.list_components(scope)
    component_by_id = Map.new(components, &{&1.id, &1})

    changed_entries =
      entries_with_owners
      |> Enum.filter(&(&1.path in changed_set))
      |> Enum.map(&validate_entry(&1, base_dir, component_by_id))

    # Write validation results for changed files
    Enum.each(changed_entries, fn entry ->
      case Files.get_by_path(scope, entry.path) do
        nil -> :ok
        file -> Files.mark_validated(file, entry.valid, entry.validation_errors)
      end
    end)

    validate_ms = System.monotonic_time(:millisecond) - start - scan_ms

    # Remove files no longer on disk
    current_paths = Enum.map(file_entries, & &1.path)
    {removed, _} = Files.delete_removed(scope, current_paths)

    total_ms = System.monotonic_time(:millisecond) - start

    Logger.info(
      "[FileSync] #{length(file_entries)} files scanned in #{scan_ms}ms, " <>
        "validated #{length(changed_paths)} in #{validate_ms}ms, " <>
        "#{upserted} upserted, #{removed} removed, total #{total_ms}ms"
    )

    {:ok,
     %{
       upserted: upserted,
       removed: removed,
       changed_paths: changed_paths,
       total_files: length(file_entries)
     }}
  end

  @doc """
  Stream and classify all trackable files from a directory.

  Returns a stream of maps with `:path`, `:role`, `:mtime`, `:size`.
  """
  @spec stream_files(String.t(), [String.t()]) :: Enumerable.t()
  def stream_files(base_dir, ignored_patterns \\ []) do
    DirWalker.stream(base_dir)
    |> Stream.map(&Path.relative_to(&1, base_dir))
    |> Stream.reject(&ignored_path?/1)
    |> Stream.reject(&matches_ignored_pattern?(&1, ignored_patterns))
    |> Stream.map(&classify/1)
    |> Stream.reject(&is_nil/1)
    |> Stream.map(fn {path, role} -> stat_file(base_dir, path, role) end)
    |> Stream.reject(&is_nil/1)
  end

  # -- Inline validation for changed files --

  defp validate_entry(%{role: :spec} = entry, base_dir, component_by_id) do
    abs_path = Path.join(base_dir, entry.path)

    case Elixir.File.read(abs_path) do
      {:ok, content} ->
        document_type = resolve_document_type(entry, component_by_id)
        validate_spec_content(entry, content, document_type)

      {:error, reason} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: "Read failed: #{inspect(reason)}"}})
    end
  end

  defp validate_entry(%{role: role} = entry, _base_dir, _component_by_id)
       when role in [:implementation, :test, :rule, :config, :bdd_spec, :qa_brief, :qa_result, :json, :review, :architecture] do
    # These roles are valid if they exist (which they do, since FileSync found them)
    Map.merge(entry, %{valid: true, validation_errors: nil})
  end

  defp validate_entry(entry, _base_dir, _component_by_id) do
    Map.merge(entry, %{valid: nil, validation_errors: nil})
  end

  defp validate_spec_content(entry, content, document_type) do
    case Documents.create_dynamic_document(content, document_type) do
      {:ok, _document} ->
        Map.merge(entry, %{valid: true, validation_errors: nil})

      {:error, error} ->
        Map.merge(entry, %{valid: false, validation_errors: %{error: to_string(error)}})
    end
  rescue
    e ->
      Map.merge(entry, %{valid: false, validation_errors: %{error: Exception.message(e)}})
  end

  defp resolve_document_type(%{component_id: nil}, _component_by_id), do: "spec"

  defp resolve_document_type(%{component_id: component_id}, component_by_id) do
    case Map.get(component_by_id, component_id) do
      nil -> "spec"
      component ->
        type_def = ComponentRegistry.get_type(component.type)
        Map.get(type_def, :document_type, "spec")
    end
  end

  @doc """
  Classify a relative path into a file role.

  Returns `{path, role}` or `nil` if the path doesn't match any known pattern.
  """
  @spec classify(String.t()) :: {String.t(), atom()} | nil
  def classify(path) do
    cond do
      match?(<<_::binary-size(1), _::binary>>, path) and String.ends_with?(path, ".spec.md") and
          String.starts_with?(path, Paths.spec_dir() <> "/") ->
        {path, :spec}

      String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex") ->
        {path, :implementation}

      String.starts_with?(path, "test/") and String.ends_with?(path, "_test.exs") ->
        {path, :test}

      String.starts_with?(path, "test/spex/") and String.ends_with?(path, "_spex.exs") ->
        {path, :bdd_spec}

      String.starts_with?(path, Paths.rules_dir() <> "/") and String.ends_with?(path, ".md") ->
        {path, :rule}

      match_qa_file?(path, "brief.md") ->
        {path, :qa_brief}

      match_qa_result?(path) ->
        {path, :qa_result}

      String.starts_with?(path, Paths.architecture_dir() <> "/") and String.ends_with?(path, ".md") ->
        {path, :architecture}

      path == "CLAUDE.md" ->
        {path, :config}

      path == Path.join(Paths.base_dir(), "config.yml") ->
        {path, :config}

      true ->
        nil
    end
  end

  # -- Private --

  defp ignored_path?(path) do
    first_segment = path |> String.split("/") |> hd()
    first_segment in @ignored_dirs
  end

  defp matches_ignored_pattern?(_path, []), do: false

  defp matches_ignored_pattern?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      if String.contains?(pattern, "*") do
        # Glob pattern — convert to regex
        regex_str =
          pattern
          |> Regex.escape()
          |> String.replace("\\*\\*", ".*")
          |> String.replace("\\*", "[^/]*")

        Regex.match?(~r/^#{regex_str}/, path)
      else
        # Exact path or prefix match
        path == pattern or String.starts_with?(path, pattern <> "/")
      end
    end)
  end

  defp load_ignored_paths(%Scope{cwd: nil}), do: []

  defp load_ignored_paths(%Scope{cwd: cwd}) do
    case Scope.read_local_config(cwd) do
      {:ok, config} ->
        case config["ignored_paths"] do
          list when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  # .code_my_spec/qa/{story_id}/brief.md
  defp match_qa_file?(path, filename) do
    qa_prefix = Paths.qa_dir() <> "/"
    String.starts_with?(path, qa_prefix) and String.ends_with?(path, "/" <> filename)
  end

  # .code_my_spec/qa/{story_id}/result.md or result_complete.md or result_failed_*.md
  defp match_qa_result?(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    String.starts_with?(path, qa_prefix) and
      String.ends_with?(path, ".md") and
      (path |> Path.basename() |> String.starts_with?("result"))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stat_file(base_dir, path, role) do
    abs_path = Path.join(base_dir, path)

    case File.stat(abs_path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime_posix}} ->
        mtime = DateTime.from_unix!(mtime_posix) |> DateTime.truncate(:second)
        %{path: path, role: role, mtime: mtime, size: size}

      _ ->
        nil
    end
  end

  defp resolve_owners(scope, entries) do
    # Build component lookup: module_name → component_id
    components = Components.list_components(scope)
    component_by_module = Map.new(components, &{&1.module_name, &1.id})

    # Build story lookup: story_id (integer) for qa/bdd_spec files
    story_ids = extract_story_ids(entries)
    story_by_id = load_stories_by_id(scope, story_ids)

    Enum.map(entries, fn entry ->
      {component_id, story_id} =
        owner_for(entry.path, entry.role, component_by_module, story_by_id)

      Map.merge(entry, %{component_id: component_id, story_id: story_id})
    end)
  end

  defp owner_for(path, role, component_by_module, _story_by_id)
       when role in [:implementation, :test, :spec] do
    module_name = path_to_module_name(path, role)
    {Map.get(component_by_module, module_name), nil}
  end

  defp owner_for(path, :bdd_spec, _component_by_module, story_by_id) do
    # test/spex/{story_id_and_title}/criterion_*_spex.exs → story
    story_id = extract_story_id_from_spex_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(path, role, _component_by_module, story_by_id)
       when role in [:qa_brief, :qa_result] do
    # .code_my_spec/qa/{story_id}/brief.md → story
    story_id = extract_story_id_from_qa_path(path)
    {nil, story_by_id[story_id]}
  end

  defp owner_for(_path, _role, _component_by_module, _story_by_id), do: {nil, nil}

  # .code_my_spec/qa/440/brief.md → 440
  defp extract_story_id_from_qa_path(path) do
    qa_prefix = Paths.qa_dir() <> "/"

    path
    |> String.replace_prefix(qa_prefix, "")
    |> String.split("/")
    |> hd()
    |> parse_integer()
  end

  # test/spex/424_user_registration.../criterion_*_spex.exs → 424
  defp extract_story_id_from_spex_path(path) do
    path
    |> String.replace_prefix("test/spex/", "")
    |> String.split("/")
    |> hd()
    |> String.split("_")
    |> hd()
    |> parse_integer()
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp extract_story_ids(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case entry.role do
        :bdd_spec -> [extract_story_id_from_spex_path(entry.path)]
        role when role in [:qa_brief, :qa_result] -> [extract_story_id_from_qa_path(entry.path)]
        _ -> []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_stories_by_id(_scope, []), do: %{}

  defp load_stories_by_id(scope, story_ids) do
    import Ecto.Query

    CodeMySpec.Stories.Story
    |> where([s], s.project_id == ^scope.active_project_id and s.id in ^story_ids)
    |> select([s], {s.id, s.id})
    |> CodeMySpec.Repo.all()
    |> Map.new()
  end

  defp path_to_module_name(path, :implementation) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :test) do
    path
    |> String.replace_prefix("test/", "")
    |> String.replace_suffix("_test.exs", "")
    |> path_segments_to_module()
  end

  defp path_to_module_name(path, :spec) do
    path
    |> String.replace_prefix(Paths.spec_dir() <> "/", "")
    |> String.replace_suffix(".spec.md", "")
    |> path_segments_to_module()
  end

  defp path_segments_to_module(path) do
    path
    |> String.split("/")
    |> Enum.map_join(".", fn segment ->
      segment
      |> String.split("_")
      |> Enum.map_join(&String.capitalize/1)
    end)
  end
end

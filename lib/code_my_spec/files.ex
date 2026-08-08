defmodule CodeMySpec.Files do
  @moduledoc """
  Context for managing tracked project files.
  """

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Harnesses
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Build the `ReadModel` a scan needs: component module names, the project's
  story ids, and whether validation is strict.

  Here rather than on `Scanner` because it is the one part of scanning that
  touches a database, and `Scanner` now ships in `cms_scan` so the light harness
  can classify files without one. Everything else in that module is a function
  of (environment, read model); this is where the read model comes from when
  there *is* a database. A harness fetches the same struct over its channel.
  """
  @spec read_model(Scope.t()) :: ReadModel.t()
  def read_model(%Scope{} = scope) do
    components = Components.list_components(scope)

    %ReadModel{
      component_by_module: Map.new(components, &{&1.module_name, &1.id}),
      component_by_id: Map.new(components, &{&1.id, &1}),
      story_ids: project_story_ids(scope),
      story_by_spec_path: story_by_spec_path(scope),
      strict?: Configurations.require_specs?(scope)
    }
  end

  # Which story owns each spex file, according to the criteria themselves.
  #
  # A criterion records the file that is its spex, so this makes a spex file's
  # owner a lookup instead of a number parsed out of a directory name. Those
  # numbers are per-deployment: after a migration every directory names a story
  # with a different id here, so the parse silently stops finding anything and
  # `bdd_specs_exist` reads as work not done.
  defp story_by_spec_path(%Scope{active_project_id: nil}), do: %{}

  defp story_by_spec_path(%Scope{} = scope) do
    CodeMySpec.AcceptanceCriteria.Criterion
    |> where([c], c.project_id == ^scope.active_project_id)
    |> where([c], not is_nil(c.spec_path) and c.spec_path != "")
    |> select([c], {c.spec_path, c.story_id})
    |> Repo.all()
    |> Map.new()
  end

  defp project_story_ids(%Scope{active_project_id: nil}), do: MapSet.new()

  defp project_story_ids(%Scope{} = scope) do
    CodeMySpec.Stories.Story
    |> where([s], s.project_id == ^scope.active_project_id)
    |> select([s], s.id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "List all files for the project."
  @spec list_files(Scope.t()) :: [File.t()]
  def list_files(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc """
  List files for the project with the owning component preloaded, ordered by
  path, with optional pagination and validity filtering.

  Options:
  - `:page` — 1-based page number (default `1`)
  - `:per_page` — page size (default `25`)
  - `:filter` — `:all` (default) or `:invalid` to restrict to `valid: false`
  """
  @spec list_files_paginated(Scope.t(), keyword()) :: %{
          files: [File.t()],
          page: pos_integer(),
          per_page: pos_integer(),
          total_count: non_neg_integer(),
          unfiltered_count: non_neg_integer(),
          invalid_count: non_neg_integer(),
          total_pages: pos_integer(),
          filter: :all | :invalid
        }
  def list_files_paginated(%Scope{active_project_id: project_id} = scope, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = max(Keyword.get(opts, :per_page, 25), 1)
    filter = Keyword.get(opts, :filter, :all)

    project_scope =
      File |> where([f], f.project_id == ^project_id) |> scope_to_harness(scope)

    unfiltered_count = Repo.aggregate(project_scope, :count, :id)

    invalid_count =
      project_scope
      |> where([f], f.valid == false)
      |> Repo.aggregate(:count, :id)

    base = apply_filter(project_scope, filter)
    total_count = Repo.aggregate(base, :count, :id)
    total_pages = max(div(total_count + per_page - 1, per_page), 1)

    files =
      base
      |> order_by([f], asc: f.path)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> preload(:component)
      |> Repo.all()

    %{
      files: files,
      page: page,
      per_page: per_page,
      total_count: total_count,
      unfiltered_count: unfiltered_count,
      invalid_count: invalid_count,
      total_pages: total_pages,
      filter: filter
    }
  end

  defp apply_filter(query, :invalid), do: where(query, [f], f.valid == false)
  defp apply_filter(query, _), do: query

  @doc "List files for a specific component."
  @spec list_component_files(Scope.t(), Ecto.UUID.t()) :: [File.t()]
  def list_component_files(%Scope{active_project_id: project_id} = scope, component_id) do
    File
    |> where([f], f.project_id == ^project_id and f.component_id == ^component_id)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc "List files for a specific story."
  @spec list_story_files(Scope.t(), integer()) :: [File.t()]
  def list_story_files(%Scope{active_project_id: project_id} = scope, story_id) do
    File
    |> where([f], f.project_id == ^project_id and f.story_id == ^story_id)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc "Get a file by path within the project."
  @spec get_by_path(Scope.t(), String.t()) :: File.t() | nil
  # `limit(1)` because a path is unique per *working copy*, not per project: two
  # checkouts each holding `lib/foo.ex` is ordinary now, and `Repo.one/1` raises
  # on two rows. A scope naming a harness gets that copy's file; one that does
  # not is asking about the project, where any copy's answer will do.
  def get_by_path(%Scope{active_project_id: project_id} = scope, path) do
    File
    |> where([f], f.project_id == ^project_id and f.path == ^path)
    |> scope_to_harness(scope)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Get multiple files by paths."
  @spec get_by_paths(Scope.t(), [String.t()]) :: [File.t()]
  def get_by_paths(%Scope{active_project_id: project_id} = scope, paths) when is_list(paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path in ^paths)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc """
  Bulk upsert files. Inserts new files or updates mtime/size/role/owner for existing ones.

  Returns `{inserted_count, updated_files}`.
  """
  # SQLite's compile-time `SQLITE_MAX_VARIABLE_NUMBER` is 32766. With 13
  # bound columns per File row, anything above ~2500 rows in a single
  # `insert_all` raises `Exqlite.Error: variable number must be between
  # ?1 and ?32766`. Chunk well under that for headroom — projects with
  # large hex doc corpora can easily run thousands of tracked files.
  @upsert_chunk_size 500

  # Fields the scanner computes for its own decisions and that are not columns.
  # `insert_all` rejects an unknown key outright, so dropping them here rather
  # than in each caller means a new scratch field cannot break a sync path that
  # happens not to clear it — which is exactly how `:declared_module` broke
  # `sync_path/3` and `sync_changed/2` while the full sync was fine.
  @scanner_scratch [:declared_module, :raw_role]

  @spec upsert_files(Scope.t(), [map()]) :: {integer(), [File.t()] | nil}
  def upsert_files(%Scope{active_project_id: project_id} = scope, file_attrs_list)
      when is_list(file_attrs_list) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # A writer that named its working copy gets that one; one that did not gets
    # the project's nil-object harness. `harness_id` is NOT NULL because
    # `conflict_target` has to name a unique index and ON CONFLICT never matches
    # a null — so "no working copy" needs a row to point at rather than a hole.
    harness_id = scope.active_harness_id || Harnesses.ensure_default(scope)

    entries =
      Enum.map(file_attrs_list, fn attrs ->
        attrs
        |> Map.drop(@scanner_scratch)
        |> Map.put(:project_id, project_id)
        |> Map.put(:harness_id, harness_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {total_count, files} =
      entries
      |> Enum.chunk_every(@upsert_chunk_size)
      |> Enum.reduce({0, []}, fn chunk, {acc_count, acc_files} ->
        {count, batch} =
          Repo.insert_all(File, chunk,
            on_conflict:
              {:replace,
               [
                 :role,
                 :mtime,
                 :size,
                 :fingerprint,
                 :component_id,
                 :story_id,
                 :valid,
                 :validation_errors,
                 :updated_at
               ]},
            conflict_target: [:project_id, :harness_id, :path],
            returning: true
          )

        {acc_count + count, acc_files ++ (batch || [])}
      end)

    {total_count, files}
  end

  @doc """
  Upsert a single file record without updating mtime.

  Used by the FileWatcher to keep role, ownership, and validation fresh
  in real-time while leaving mtime stale so `sync_changed` still picks
  up the file as changed during the stop hook validation pass.
  """
  @spec upsert_file_metadata(Scope.t(), map()) :: {:ok, File.t()} | {:error, term()}
  def upsert_file_metadata(%Scope{active_project_id: project_id} = scope, attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entry =
      attrs
      |> Map.drop(@scanner_scratch)
      |> Map.put(:project_id, project_id)
      |> Map.put(:harness_id, scope.active_harness_id || Harnesses.ensure_default(scope))
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)

    {1, [file]} =
      Repo.insert_all(File, [entry],
        on_conflict:
          {:replace,
           [
             :role,
             :size,
             :fingerprint,
             :component_id,
             :story_id,
             :valid,
             :validation_errors,
             :updated_at
           ]},
        conflict_target: [:project_id, :harness_id, :path],
        returning: true
      )

    {:ok, file}
  end

  @doc """
  Delete files that exist in DB but not in the provided path list.

  Used during sync to clean up files that were removed from the filesystem.
  """
  # Scoped to the harness that produced the manifest, and this is the line the
  # whole grain change exists for. A full reconcile deletes whatever the scan
  # did not see — unscoped, that meant every sync deleted the *other* checkout's
  # files, so two working copies of one project each erased the other on every
  # scan and the requirement graph described neither.
  #
  # A scope with no harness deletes across the project, which is what a caller
  # holding the whole project rather than one copy of it means. Only the channel
  # sets a harness, and only it sends manifests.
  @spec delete_removed(Scope.t(), [String.t()]) :: {integer(), nil}
  def delete_removed(%Scope{active_project_id: project_id} = scope, current_paths)
      when is_list(current_paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path not in ^current_paths)
    |> scope_to_harness(scope)
    |> Repo.delete_all()
  end

  # `is_nil(f.harness_id)` is deliberately *not* matched when a harness is set:
  # a row owned by nobody is not this checkout's to delete, and leaving it makes
  # the state visible rather than quietly disappearing it.
  defp scope_to_harness(query, %Scope{active_harness_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_harness_id: harness_id}),
    do: where(query, [f], f.harness_id == ^harness_id)

  @doc """
  Delete specific files by their paths.

  Used for targeted removal when the file watcher detects file deletions.
  """
  @spec delete_by_paths(Scope.t(), [String.t()]) :: {integer(), nil}
  def delete_by_paths(%Scope{active_project_id: project_id}, paths)
      when is_list(paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path in ^paths)
    |> Repo.delete_all()
  end

  @doc """
  Find files that changed — mtime in DB differs from provided mtime map.

  Takes a map of `%{path => mtime}` and returns File records where the stored
  mtime is older than the filesystem mtime (or the file is new).
  """
  @spec changed_files(Scope.t(), %{String.t() => DateTime.t()}) :: [File.t()]
  def changed_files(%Scope{active_project_id: project_id}, path_mtime_map)
      when is_map(path_mtime_map) do
    paths = Map.keys(path_mtime_map)

    existing =
      File
      |> where([f], f.project_id == ^project_id and f.path in ^paths)
      |> Repo.all()
      |> Map.new(&{&1.path, &1})

    Enum.filter(paths, fn path ->
      case Map.get(existing, path) do
        nil -> true
        file -> DateTime.compare(Map.fetch!(path_mtime_map, path), file.mtime) == :gt
      end
    end)
    |> Enum.map(fn path -> Map.get(existing, path) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  List files whose on-disk content changed since a given timestamp.

  Useful for finding what changed during a task: pass `task.started_at`.
  Optionally filter by component_id or story_id.

  Compares against the file's `mtime` (captured at sync from the
  filesystem), not the DB row's `updated_at` — the validation pipeline
  itself writes to rows (e.g. `validation_errors`) which would otherwise
  make every previously-touched file look freshly "changed" on every
  subsequent stop turn.
  """
  @spec changed_since(Scope.t(), DateTime.t(), keyword()) :: [File.t()]
  def changed_since(%Scope{active_project_id: project_id} = scope, since, opts \\ []) do
    component_id = Keyword.get(opts, :component_id)
    story_id = Keyword.get(opts, :story_id)

    File
    |> where([f], f.project_id == ^project_id and f.mtime >= ^since)
    |> scope_to_harness(scope)
    |> then(fn q ->
      if component_id, do: where(q, [f], f.component_id == ^component_id), else: q
    end)
    |> then(fn q ->
      if story_id, do: where(q, [f], f.story_id == ^story_id), else: q
    end)
    |> order_by([f], asc: f.path)
    |> Repo.all()
  end

  @doc "List files that need validation (valid is nil)."
  @spec files_needing_validation(Scope.t()) :: [File.t()]
  def files_needing_validation(%Scope{active_project_id: project_id}) do
    File
    |> where([f], f.project_id == ^project_id and is_nil(f.valid))
    |> Repo.all()
  end

  @doc "Mark a file as validated (pass or fail)."
  @spec mark_validated(File.t(), boolean(), map() | nil) ::
          {:ok, File.t()} | {:error, Ecto.Changeset.t()}
  def mark_validated(%File{} = file, valid, errors \\ nil) do
    file
    |> File.changeset(%{valid: valid, validation_errors: errors})
    |> Repo.update()
  end

  @doc """
  Check if a component has a file with the given role.
  """
  @spec has_file?(Scope.t(), Ecto.UUID.t(), atom()) :: boolean()
  def has_file?(%Scope{active_project_id: project_id}, component_id, role) do
    File
    |> where(
      [f],
      f.project_id == ^project_id and f.component_id == ^component_id and f.role == ^role
    )
    |> Repo.exists?()
  end

  @doc """
  Check if a component has a valid file with the given role.
  """
  @spec has_valid_file?(Scope.t(), Ecto.UUID.t(), atom()) :: boolean()
  def has_valid_file?(%Scope{active_project_id: project_id}, component_id, role) do
    File
    |> where(
      [f],
      f.project_id == ^project_id and
        f.component_id == ^component_id and
        f.role == ^role and
        f.valid == true
    )
    |> Repo.exists?()
  end
end

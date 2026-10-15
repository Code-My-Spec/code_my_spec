defmodule CodeMySpec.Files do
  @moduledoc """
  Context for managing tracked project files.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Stories,
      CodeMySpec.BddSpecs,
      CodeMySpec.Components,
      CodeMySpec.Dependencies,
      CodeMySpec.Documents,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Requirements.Invalidations,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  import Ecto.Query

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.LiveCopies
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Files.SpecBinding
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  Build the `ReadModel` a scan needs: component module names, the project's
  story ids, and whether validation is strict.

  Here rather than on `Scanner` because it is the one part of scanning that
  touches a database: a light harness holds none and fetches the same struct
  over its channel.
  """
  @spec read_model(Scope.t()) :: ReadModel.t()
  def read_model(%Scope{} = scope) do
    components = Components.list_components(scope)

    %ReadModel{
      component_by_module: Map.new(components, &{&1.module_name, &1.id}),
      component_by_path: component_by_path(components),
      component_by_id: Map.new(components, &{&1.id, &1}),
      story_ids: project_story_ids(scope),
      story_ids_by_number: project_story_ids_by_number(scope),
      story_by_spec_path: story_by_spec_path(scope),
      strict?: false
    }
  end

  @doc """
  The `use Boundary` declarations in the project's code, as the scan recorded
  them: `%{"module", "top_level", "classify_to"}` each.

  Read from the main copy's implementation files, the same checkouts whose code
  says which components exist (`LiveCopies.speaking_ids/1`). A file scanned
  before declarations were recorded has none until its next scan.
  """
  @spec boundary_declarations(Scope.t()) :: [map()]
  def boundary_declarations(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    copies = LiveCopies.speaking_ids(project_id)

    File
    |> where([f], f.project_id == ^project_id and f.role == :implementation)
    |> where([f], f.working_copy_id in ^copies)
    |> select([f], f.validation_errors)
    |> Repo.all()
    |> Enum.flat_map(&declared_boundaries/1)
    |> Enum.uniq_by(& &1["module"])
  end

  def boundary_declarations(%Scope{}), do: []

  defp declared_boundaries(%{"data" => %{"dependency_evidence" => %{"boundaries" => list}}})
       when is_list(list),
       do: list

  defp declared_boundaries(_), do: []

  # Every path each component conventionally owns, pointing back at it. Built
  # module → path because only that direction is exact (`Git.CLI` cannot be
  # derived from its path); see `Components.ConventionalPaths`. Later
  # components win a collision — a naming conflict the architecture layer owns.
  defp component_by_path(components) do
    for component <- components,
        path <- ConventionalPaths.for_component(component),
        into: %{},
        do: {path, component.id}
  end

  # Which story owns each spex file, according to the criteria themselves — a
  # lookup, not a number parsed from a directory name (numbers are
  # per-deployment and silently stop matching after a migration).
  defp story_by_spec_path(%Scope{active_project_id: nil}), do: %{}

  defp story_by_spec_path(%Scope{} = scope) do
    CodeMySpec.Stories.AcceptanceCriteria.Criterion
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

  # `test/spex/<number>_<slug>/` names a story by its durable number; every
  # File row keys on the primary key. This is the join between them.
  defp project_story_ids_by_number(%Scope{active_project_id: nil}), do: %{}

  defp project_story_ids_by_number(%Scope{} = scope) do
    CodeMySpec.Stories.Story
    |> where([s], s.project_id == ^scope.active_project_id and not is_nil(s.number))
    |> select([s], {s.number, s.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc "List all files for the project."
  @spec list_files(Scope.t()) :: [File.t()]
  def list_files(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc "This checkout's files in one role."
  @spec list_files_with_role(Scope.t(), atom()) :: [File.t()]
  def list_files_with_role(%Scope{active_project_id: project_id} = scope, role) do
    File
    |> where([f], f.project_id == ^project_id and f.role == ^role)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc """
  The same, across every checkout of the project rather than the caller's.

  For artifacts that belong to the **project** rather than to a working copy.
  A persona is the standing case: "this project's personas are researched" has
  no per-checkout meaning, and `.code_my_spec/personas/<slug>/summary.md`
  describes the project whichever tree it was written in.

  Deliberately narrow. Reading every copy together is wrong for source files —
  one present in one checkout and absent in another reads as present, which is
  why `list_files/1` scopes to the harness. Use this only where the entity
  checked is itself project-scoped; otherwise a persona written in a worktree
  is invisible to a scope bound to another checkout.
  """
  @spec list_project_files(Scope.t()) :: [File.t()]
  def list_project_files(%Scope{active_project_id: project_id}) do
    File
    |> where([f], f.project_id == ^project_id)
    |> Repo.all()
  end

  @doc """
  The project's files in these roles, across every checkout.

  `list_project_files/1` narrowed to the roles the caller reads, so a checker
  run on every graph pass (`PersonasChecker`) does not load every file of the
  project.
  """
  @spec list_project_files_with_roles(Scope.t(), [atom()]) :: [File.t()]
  def list_project_files_with_roles(%Scope{active_project_id: project_id}, roles) do
    File
    |> where([f], f.project_id == ^project_id and f.role in ^roles)
    |> Repo.all()
  end

  @doc """
  Which graph entities own these paths, in this checkout.

  `{"component", id}` and `{"story", id}` for owned files, and `:project` for a
  file with neither — the proposal, a credo check, a knowledge doc — which is
  the same three-way split `Preloader` makes into `files_by_component`,
  `files_by_story` and `files_by_project`, and the same one the project
  requirements read.

  For a writer that knows which paths it touched and needs to say which entities
  moved. Resolvable only for paths that still have rows, which is why a sync
  that *removed* files cannot use this — see `FileSync`'s `sync_entities/3`.
  """
  @spec owners_of_paths(Scope.t(), [String.t()] | :all) :: [
          {String.t(), term()} | :project
        ]
  # `:all` (a source-wide clear) has no paths to resolve owners from. `[]` is
  # what `GraphInputs.announce/4` reads as "something moved and this writer
  # cannot say what", recorded project-wide — exactly true here.
  def owners_of_paths(%Scope{}, :all), do: []

  def owners_of_paths(%Scope{active_project_id: project_id} = scope, paths)
      when is_list(paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path in ^paths)
    |> scope_to_harness(scope)
    |> select([f], {f.component_id, f.story_id})
    |> Repo.all()
    |> Enum.map(fn
      {component_id, _} when not is_nil(component_id) -> {"component", component_id}
      {_, story_id} when not is_nil(story_id) -> {"story", story_id}
      _ -> :project
    end)
    |> Enum.uniq()
  end

  @doc """
  This checkout's file paths under any of these prefixes.

  For a checker that asks about a fixed handful of locations rather than the
  whole tree (`SpexBoundaryChecker`).

  Paths only. Over-matching is safe by construction: `LIKE` treats `_` as a
  wildcard and these prefixes contain them, so this can return more than asked
  for and never less. Every caller re-checks with `starts_with?` or
  `MapSet.member?`.
  """
  @spec list_paths_under(Scope.t(), [String.t()]) :: MapSet.t(String.t())
  def list_paths_under(%Scope{active_project_id: project_id} = scope, prefixes) do
    patterns = Enum.map(prefixes, &(&1 <> "%"))

    File
    |> where([f], f.project_id == ^project_id)
    |> where([f], fragment("? LIKE ANY(?)", f.path, ^patterns))
    |> scope_to_harness(scope)
    |> select([f], f.path)
    |> Repo.all()
    |> MapSet.new()
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

  @doc """
  The components this working copy actually has files for.

  Components are project-level — a component id is stable and stories and
  requirements link to it. Whether a *checkout* has a spec for it is per
  working copy, answered here from `files.component_id` and
  `files.working_copy_id`: a checkout that has not pulled a deletion must not
  make every other checkout see an orphan.

  Excludes working copies whose `path_missing_since` is set: a copy that no
  longer exists cannot send a final manifest, so its last claim would
  otherwise stand forever. Scoped to one working copy this is a no-op.
  """
  @spec component_ids_present(Scope.t()) :: MapSet.t(Ecto.UUID.t())
  def component_ids_present(%Scope{active_project_id: project_id} = scope) do
    File
    |> join(:inner, [f], wc in WorkingCopies.WorkingCopy, on: wc.id == f.working_copy_id)
    |> where(
      [f, wc],
      f.project_id == ^project_id and not is_nil(f.component_id) and
        is_nil(wc.path_missing_since)
    )
    |> scope_to_reading_copy(scope)
    |> select([f], f.component_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # A reader that named no checkout is answered from the project's main one
  # (`WorkingCopies.reading_copy_id/1`), not a blend of every checkout: a blend
  # reads one worktree's stray spec as present everywhere. A project with no
  # main copy still blends. See knowledge/platform, "Files and working copies".
  defp scope_to_reading_copy(query, %Scope{active_working_copy_id: copy} = scope) do
    case copy || WorkingCopies.reading_copy_id(scope) do
      nil -> query
      reading -> where(query, [f], f.working_copy_id == ^reading)
    end
  end

  # A `component_id` naming a component another harness's `ComponentSync` just
  # pruned would fail the whole insert (FK), roll back the manifest and crash
  # the reconcile. Dropping the id costs one link, which the next sync
  # restores. This narrows the race, not closes it.
  # See knowledge/platform, "Files and working copies".
  defp drop_missing_component_ids(entries) do
    entries
    |> Enum.map(&Map.get(&1, :component_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> drop_absent_links(entries)
  end

  defp drop_absent_links([], entries), do: entries

  defp drop_absent_links(ids, entries) do
    present = present_component_ids(ids)

    ids
    |> Enum.reject(&MapSet.member?(present, &1))
    |> warn_dropped_links()

    Enum.map(entries, &clear_absent_link(&1, present))
  end

  defp present_component_ids(ids) do
    Components.Component
    |> where([c], c.id in ^ids)
    |> select([c], c.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp warn_dropped_links([]), do: :ok

  defp warn_dropped_links(missing) do
    Logger.warning(
      "[Files] dropped #{length(missing)} component link(s) whose component " <>
        "no longer exists: #{Enum.join(missing, ", ")}. Another working copy " <>
        "pruned them mid-sync; the next sync re-links whatever comes back."
    )
  end

  defp clear_absent_link(entry, present),
    do: clear_absent_link(entry, Map.get(entry, :component_id), present)

  defp clear_absent_link(entry, nil, _present), do: entry

  defp clear_absent_link(entry, id, present) do
    if MapSet.member?(present, id), do: entry, else: Map.put(entry, :component_id, nil)
  end

  @doc "List files for a specific story."
  @spec list_story_files(Scope.t(), integer()) :: [File.t()]
  def list_story_files(%Scope{active_project_id: project_id} = scope, story_id) do
    File
    |> where([f], f.project_id == ^project_id and f.story_id == ^story_id)
    |> scope_to_harness(scope)
    |> Repo.all()
  end

  @doc """
  Every BDD spec file's owning story, keyed by path.

  The linkage the sync already resolves, offered as a map so a caller holding a
  file path — a `Problems` row, say — can name its story without parsing the
  path.

  Spex directories are named from `story.number` in some places and
  `story.id` in others, so parsing the path matches the wrong story or none.
  `files.story_id` is resolved at sync time from the spec itself, so nothing
  here depends on a naming convention.
  """
  @spec bdd_spec_story_id_by_path(Scope.t()) :: %{String.t() => integer()}
  def bdd_spec_story_id_by_path(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id and f.role == :bdd_spec)
    |> where([f], not is_nil(f.story_id))
    |> scope_to_harness(scope)
    |> select([f], {f.path, f.story_id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Each spex file on this working copy and the criterion number its `spex` call
  names (`Files.SpecBinding`), as `%{path => number}`. Which criterion a file
  covers is this number joined to `criteria.number`.
  """
  @spec bdd_spec_criterion_numbers(Scope.t()) :: %{String.t() => integer()}
  def bdd_spec_criterion_numbers(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id and f.role == :bdd_spec)
    |> where([f], not is_nil(f.criterion_number))
    |> scope_to_harness(scope)
    |> select([f], {f.path, f.criterion_number})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Why each spex on this working copy covers nothing although it names a
  criterion — an unknown or retired number, or one another spex already
  covers — as `%{path => reason}`. Read from the numbers files name and the
  criteria as they are now, not stored.
  """
  @spec spec_problems(Scope.t()) :: %{String.t() => String.t()}
  def spec_problems(%Scope{active_project_id: project_id} = scope) do
    specs =
      File
      |> where([f], f.project_id == ^project_id and f.role == :bdd_spec)
      |> where([f], not is_nil(f.criterion_number))
      |> scope_to_harness(scope)
      |> Repo.all()

    SpecBinding.problems(scope, specs)
  end

  @doc "Get a file by path within the project."
  @spec get_by_path(Scope.t(), String.t()) :: File.t() | nil
  # `limit(1)`: a path is unique per *working copy*, not per project. A scope
  # naming a harness gets that copy's file; one that does not gets any copy's.
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
  Which of `paths` any checkout of the project still tracks.

  Project-wide on purpose, unlike `get_by_paths/2`: a spec held by one
  checkout is work on disk whichever checkout asks.
  """
  @spec tracked_in_project(Scope.t(), [String.t()]) :: MapSet.t(String.t())
  def tracked_in_project(%Scope{active_project_id: project_id}, paths) when is_list(paths) do
    File
    |> where([f], f.project_id == ^project_id and f.path in ^paths)
    |> select([f], f.path)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Bulk upsert files. Inserts new files or updates mtime/size/role/owner for existing ones.

  Returns `{inserted_count, updated_files}`.
  """
  # SQLite's `SQLITE_MAX_VARIABLE_NUMBER` is 32766 bound variables per
  # statement; chunked well under that for large corpora.
  @upsert_chunk_size 500

  # Scanner-only fields that are not columns. `insert_all` rejects unknown
  # keys, so they are dropped here once rather than in every caller.
  @scanner_scratch [:declared_module, :raw_role]

  # Everything an upsert overwrites on an existing row. `on_conflict_changed_only/0`
  # spells out the same columns and nothing links the two, so change both
  # together. `:mtime` is included: `sync_changed` reads stored mtime to
  # decide what to re-examine.
  @replaceable_fields [
    :role,
    :mtime,
    :size,
    :fingerprint,
    :component_id,
    :story_id,
    :criterion_number,
    :valid,
    :validation_errors
  ]

  @spec upsert_files(Scope.t(), [map()]) :: {integer(), [File.t()] | nil}
  def upsert_files(%Scope{active_project_id: project_id} = scope, file_attrs_list)
      when is_list(file_attrs_list) do
    now = NaiveDateTime.utc_now()

    # A writer that named its working copy gets that one; one that did not gets
    # the project's nil-object harness. `working_copy_id` is NOT NULL because
    # ON CONFLICT never matches a null.
    working_copy_id = scope.active_working_copy_id || WorkingCopies.ensure_default(scope)

    entries =
      Enum.map(file_attrs_list, fn attrs ->
        attrs
        |> Map.drop(@scanner_scratch)
        |> Map.put_new(:criterion_number, nil)
        |> Map.put(:project_id, project_id)
        |> Map.put(:working_copy_id, working_copy_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)
      |> drop_missing_component_ids()

    {total_count, files} =
      entries
      |> Enum.chunk_every(@upsert_chunk_size)
      |> Enum.reduce({0, []}, fn chunk, {acc_count, acc_files} ->
        {count, batch} =
          Repo.insert_all(File, chunk,
            on_conflict: on_conflict_changed_only(),
            conflict_target: [:project_id, :working_copy_id, :path],
            returning: true
          )

        {acc_count + count, acc_files ++ (batch || [])}
      end)

    {total_count, files}
  end

  # The whole of "what changed", decided by the database: a conflicting row is
  # updated only when a replaceable column differs, and `RETURNING` hands back
  # exactly the rows written. One statement is the write and the diff; a cold
  # table returns every row.
  #
  # `component_id` coalesces and `story_id` does not, on purpose: a manifest
  # that cannot resolve a component must not drop one the server worked out,
  # while a story the resolver drops is a real clearing.
  # See knowledge/platform, "Files and working copies".
  defp on_conflict_changed_only do
    from(f in File,
      update: [
        set: [
          role: fragment("EXCLUDED.role"),
          mtime: fragment("EXCLUDED.mtime"),
          size: fragment("EXCLUDED.size"),
          fingerprint: fragment("EXCLUDED.fingerprint"),
          valid: fragment("EXCLUDED.valid"),
          validation_errors: fragment("EXCLUDED.validation_errors"),
          component_id: fragment("COALESCE(EXCLUDED.component_id, ?)", f.component_id),
          story_id: fragment("EXCLUDED.story_id"),
          criterion_number: fragment("EXCLUDED.criterion_number"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where:
        fragment(
          """
          (?, ?, ?, ?, ?, ?, ?, ?, ?) IS DISTINCT FROM
          (EXCLUDED.role, EXCLUDED.mtime, EXCLUDED.size, EXCLUDED.fingerprint,
           EXCLUDED.valid, EXCLUDED.validation_errors,
           COALESCE(EXCLUDED.component_id, ?), EXCLUDED.story_id, EXCLUDED.criterion_number)
          """,
          f.role,
          f.mtime,
          f.size,
          f.fingerprint,
          f.valid,
          f.validation_errors,
          f.component_id,
          f.story_id,
          f.criterion_number,
          f.component_id
        )
    )
  end

  @doc """
  The columns an upsert overwrites on an existing row.

  Also the definition of "this row needs writing": an entry matching the stored
  row on every one of these would change nothing but `updated_at`.
  `on_conflict_changed_only/0` compares the same columns; keep them in step.

  `:updated_at` is excluded: it is written on every upsert by definition.
  """
  @spec replaceable_fields() :: [atom()]
  def replaceable_fields, do: @replaceable_fields

  @doc """
  Upsert a single file record without updating mtime.

  Used by single-path sync to keep role, ownership, and validation fresh
  in real-time while leaving mtime stale so `sync_changed` still picks
  up the file as changed during the stop hook validation pass.
  """
  @spec upsert_file_metadata(Scope.t(), map()) :: {:ok, File.t()} | {:error, term()}
  def upsert_file_metadata(%Scope{active_project_id: project_id} = scope, attrs) do
    now = NaiveDateTime.utc_now()

    entry =
      attrs
      |> Map.drop(@scanner_scratch)
      |> Map.put_new(:criterion_number, nil)
      |> Map.put(:project_id, project_id)
      |> Map.put(
        :working_copy_id,
        scope.active_working_copy_id || WorkingCopies.ensure_default(scope)
      )
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
             :criterion_number,
             :valid,
             :validation_errors,
             :updated_at
           ]},
        conflict_target: [:project_id, :working_copy_id, :path],
        returning: true
      )

    {:ok, file}
  end

  @doc """
  Delete files that exist in DB but not in the provided path list.

  Used during sync to clean up files that were removed from the filesystem.
  """
  # Scoped to the harness that produced the manifest: unscoped, a full
  # reconcile deleted every *other* checkout's files. A scope with no harness
  # deletes across the project; only the channel sets a harness.
  @spec delete_removed(Scope.t(), [String.t()]) :: {integer(), nil}
  def delete_removed(%Scope{active_project_id: project_id} = scope, current_paths)
      when is_list(current_paths) do
    # `returning: true`: embedding cleanup needs each removed row's role and
    # path, without loading the table first.
    File
    |> where([f], f.project_id == ^project_id and f.path not in ^current_paths)
    |> scope_to_harness(scope)
    |> select([f], f)
    |> Repo.delete_all()
  end

  # Nil-`working_copy_id` rows are not matched when a harness is set: a row
  # owned by nobody is not this checkout's to delete.
  defp scope_to_harness(query, %Scope{active_working_copy_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

  @doc """
  Every tracked path and when it was last modified, for this checkout.

  Two columns rather than the whole table. `FileSync.sync_changed/2` uses this
  to decide which files to *open*; whether content changed is decided by the
  upsert, which returns exactly the rows it wrote.
  """
  @spec mtimes_by_path(Scope.t()) :: %{String.t() => DateTime.t()}
  def mtimes_by_path(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> select([f], {f.path, f.mtime})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Delete specific files by their paths.

  Used for targeted removal when single-path sync finds a file deleted.
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

    # `stat` mtimes resolve whole seconds; `since` keeps microseconds. Floored,
    # an edit in the task's first second counts.
    since = floor_to_second(since)

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

  defp floor_to_second(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp floor_to_second(%NaiveDateTime{} = at), do: NaiveDateTime.truncate(at, :second)
  defp floor_to_second(at), do: at

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

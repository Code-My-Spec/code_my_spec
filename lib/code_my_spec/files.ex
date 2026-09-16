defmodule CodeMySpec.Files do
  @moduledoc """
  Context for managing tracked project files.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.BddSpecs,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Documents,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  import Ecto.Query

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.Components.ConventionalPaths
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.File
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

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
      component_by_path: component_by_path(components),
      component_by_id: Map.new(components, &{&1.id, &1}),
      story_ids: project_story_ids(scope),
      story_ids_by_number: project_story_ids_by_number(scope),
      story_by_spec_path: story_by_spec_path(scope),
      strict?: Configurations.require_specs?(scope)
    }
  end

  # Every path each component conventionally owns, pointing back at it.
  #
  # Built module → path because that direction is exact; the inverse is not, and
  # a component whose name carries a run of two or more capitals (`Git.CLI`,
  # `Git.URLParser`) can never be found by deriving a module from a path. See
  # `Components.ConventionalPaths`.
  #
  # Later components win a collision, which is arbitrary and fine: two
  # components claiming one path is a naming conflict the architecture layer
  # owns, and picking a side here does not make it better or worse.
  defp component_by_path(components) do
    for component <- components,
        path <- ConventionalPaths.for_component(component),
        into: %{},
        do: {path, component.id}
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

  @doc """
  The same, across every checkout of the project rather than the caller's.

  For artifacts that belong to the **project** rather than to a working copy.
  A persona is the standing case: "this project's personas are researched" has
  no per-checkout meaning, and `.code_my_spec/personas/<slug>/summary.md`
  describes the project whichever tree it was written in.

  Deliberately narrow, and not a general-purpose lister. Reading every copy
  together is wrong for source files — one present in one checkout and absent
  in another reads as present, which is the reason `list_files/1` scopes to the
  harness and the reason the requirement graph warns when it is built without
  one. Reach for this only where the entity being checked is itself
  project-scoped.

  It exists because the alternative was silent and expensive: persona artifacts
  written in a worktree are invisible to a scope bound to another checkout, so
  a correct, validated, already-scanned file reported as missing. The MCP mount
  takes `X-Harness-Id` from `CMS_HARNESS_ID` in the environment, so a session
  that inherited one checkout's id while writing another's files hits this with
  no indication of why.
  """
  @spec list_project_files(Scope.t()) :: [File.t()]
  def list_project_files(%Scope{active_project_id: project_id}) do
    File
    |> where([f], f.project_id == ^project_id)
    |> Repo.all()
  end

  @doc """
  The project's files in these roles, across every checkout.

  `list_project_files/1` narrowed to the roles the caller actually reads.
  `PersonasChecker` was loading every file on the project — ~18,650 rows across
  five checkouts — to keep the two persona roles, and it runs on every graph
  pass because `personas_complete` is a project node and those are rebuilt
  unconditionally. Measured at 407ms of a 907ms project-node computation.

  Same answer, same scoping, four orders of magnitude fewer rows.
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
  that *removed* files cannot use this — see `FileSync.announce_graph_change/4`.
  """
  @spec owners_of_paths(Scope.t(), [String.t()] | :all) :: [
          {String.t(), term()} | :project
        ]
  # `:all` is `clear_problems_for_source/3` saying "everywhere this source
  # reported", which it does not enumerate — a `block_all` analyzer clears by
  # source, not by path. There is nothing to resolve owners from, and answering
  # `[]` is the honest reading rather than a gap: `GraphInputs.announce/3` takes
  # an empty entity list as "something moved and this writer cannot say what"
  # and records it project-wide, which is exactly true here.
  #
  # Without this clause the call raised `FunctionClauseError` *inside* the stop
  # hook's validation pipeline, so a `block_all` source took the whole stop
  # decision down with it.
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

  For a checker that asks about a fixed handful of locations rather than about
  the tree. `SpexBoundaryChecker` wanted five paths and was reading every file
  in the checkout to build a `MapSet` of all of them — 385ms of the same
  project-node computation.

  Paths only, because that is all such a checker looks at, and over-matching is
  safe by construction: `LIKE` treats `_` as a wildcard and these prefixes
  contain them, so this can return more than asked for and never less. Every
  caller re-checks with `starts_with?` or `MapSet.member?`, which is what makes
  the loose match correct rather than merely tolerable.
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

  Components are project-level on purpose — a component id is stable, and 112
  stories and 4048 requirements link to one. Whether a *checkout* has a spec for
  it is a different question, and this is the side that answers it: `files`
  carries both `component_id` and `working_copy_id`, so presence is already per
  working copy without anything moving.

  The distinction has teeth. `CodeMySpecLocalWeb.EpicsLive` was deleted from the
  spec tree on 2026-08-10 (`ad775a1`, "Move the EpicsLive specs to where the
  code actually is"). Three checkouts had not pulled, their stale spec files
  kept re-projecting the component, and every agent was told it had an orphan
  context — including the checkouts where the file was correctly gone, which
  could not resolve it because all four resolutions act on a file they do not
  have.
  """
  @spec component_ids_present(Scope.t()) :: MapSet.t(Ecto.UUID.t())
  def component_ids_present(%Scope{active_project_id: project_id} = scope) do
    File
    |> where([f], f.project_id == ^project_id and not is_nil(f.component_id))
    |> scope_to_harness(scope)
    |> select([f], f.component_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # A `component_id` naming a component that no longer exists fails the whole
  # insert, and with it the whole reconcile.
  #
  # Ownership is resolved against a read model built moments earlier in this
  # request (`Scanner.resolve_owners/2`), which is fresh — so the component was
  # there when it was read. Components are project-scoped by design, though, and
  # several working copies sync one project concurrently: another harness's
  # `ComponentSync` can prune a component between our read and our insert. The
  # result was a `files_component_id_fkey` violation that killed
  # `start_reconcile/2`, closed the channel, and had the harness reconnect and
  # do it again — a storm that repaired nothing, because the rollback discarded
  # the manifest too (issue `ef981256`).
  #
  # Dropping the id degrades instead. A file owned by nothing is wrong in a way
  # the next sync fixes — `ComponentSync` re-links it as soon as the component
  # exists again — where a crashed reconcile is wrong in a way nothing fixes.
  # One dangling id should cost one link, not every file in the manifest.
  #
  # This narrows the race rather than closing it: the check and the insert are
  # in one transaction, so the window is small, but a concurrent prune could
  # still land between them and the FK would fire as before. Closing it properly
  # means serialising reconcile per project, which is expensive in exactly the
  # case this project is built for — several agents on one project is the
  # design, not an anomaly.
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

  Parsing was the previous answer and it was wrong for most of a project. Spex
  directories are named from `story.number` in some places and `story.id` in
  others, so `derive_story_number/1` returned an id where a number was expected
  and the comparison silently matched nothing. A gate asking "does this story
  have failing specs" got `[]` and read it as "green". Measured on Broken Oaths
  2026-09-08: 38 of 54 spec directories were id-prefixed, and 47 of 61 stories
  carried `specs_ready: true` with their features unbuilt.

  `files.story_id` is resolved at sync time from the spec itself and was correct
  for every one of those directories, so nothing here needs a naming convention
  to hold.
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

  # Everything an upsert overwrites on a row that already exists, and therefore
  # everything that can make a manifest entry differ from what is stored.
  #
  # One list, two readers: `on_conflict` below and `FileSync.changed_entries/2`
  # via `replaceable_fields/0`. They have to agree, and a pair that has to agree
  # with nothing linking them is how most of this system's quiet bugs have
  # started — `@role_analyzers` against `Fingerprint.@source_roles`, the
  # generators fixture against `DeployBoilerplate.@files`, `@configurable_sources`
  # against `Run.@sources`. A field added here is compared from the moment it is
  # added.
  #
  # `:mtime` is included deliberately. A file touched without its content
  # changing has the same fingerprint and a new mtime, and `sync_changed` reads
  # stored mtime to decide what to re-examine — so treating it as no change
  # would leave that stale.
  @replaceable_fields [
    :role,
    :mtime,
    :size,
    :fingerprint,
    :component_id,
    :story_id,
    :valid,
    :validation_errors
  ]

  @spec upsert_files(Scope.t(), [map()]) :: {integer(), [File.t()] | nil}
  def upsert_files(%Scope{active_project_id: project_id} = scope, file_attrs_list)
      when is_list(file_attrs_list) do
    now = NaiveDateTime.utc_now()

    # A writer that named its working copy gets that one; one that did not gets
    # the project's nil-object harness. `working_copy_id` is NOT NULL because
    # `conflict_target` has to name a unique index and ON CONFLICT never matches
    # a null — so "no working copy" needs a row to point at rather than a hole.
    working_copy_id = scope.active_working_copy_id || WorkingCopies.ensure_default(scope)

    entries =
      Enum.map(file_attrs_list, fn attrs ->
        attrs
        |> Map.drop(@scanner_scratch)
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

  # The whole of "what changed", decided by Postgres.
  #
  # A conflicting row is updated only when one of the replaceable columns
  # actually differs, and `RETURNING` then hands back exactly the rows the
  # statement touched — inserts and real updates, nothing else. So one statement
  # is both the write and the answer to "what moved", and hydrating a cold
  # table and reconciling a warm one are the same operation: on a cold table
  # every row is new, so every row comes back.
  #
  # This replaces a hand-written diff — load the whole file table, compare eight
  # fields per observation in Elixir, upsert the survivors. That read was ~5,100
  # rows on every manifest, and the comparison has been wrong twice: once
  # judging on fingerprint alone, which hid a spex file that had gained a
  # `story_id` with its bytes untouched (`bdd_specs_exist` stayed dark on nine
  # stories through Drill 12), and once producing a false positive that took two
  # rounds of guessing to attribute. A `WHERE` cannot drift from the `SET` above
  # it the way a separate comparison drifts from the columns it is meant to
  # mirror.
  #
  # `component_id` coalesces and `story_id` does not, and the asymmetry is
  # deliberate. A manifest that cannot resolve a component must not drop one the
  # server already worked out — that was `keep_backfilled_owners/2`. A story the
  # resolver drops *is* a clearing: `spex_ownership` moves, and a stale
  # `story_id` would keep a spec file bound to a story it no longer describes.
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
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where:
        fragment(
          """
          (?, ?, ?, ?, ?, ?, ?, ?) IS DISTINCT FROM
          (EXCLUDED.role, EXCLUDED.mtime, EXCLUDED.size, EXCLUDED.fingerprint,
           EXCLUDED.valid, EXCLUDED.validation_errors,
           COALESCE(EXCLUDED.component_id, ?), EXCLUDED.story_id)
          """,
          f.role,
          f.mtime,
          f.size,
          f.fingerprint,
          f.valid,
          f.validation_errors,
          f.component_id,
          f.story_id,
          f.component_id
        )
    )
  end

  @doc """
  The columns an upsert overwrites on an existing row.

  Exported because it is also the definition of "this row needs writing": a
  manifest entry matching the stored row on every one of these would produce an
  `insert_all` that changes nothing but `updated_at`. `FileSync` reads this to
  decide what to send, so the two cannot drift — a field added to the replace
  list is compared from the moment it is added, rather than becoming a change
  the diff silently cannot see.

  `:updated_at` is excluded: it is written on every upsert by definition, and
  comparing it would make every row differ from itself.
  """
  @spec replaceable_fields() :: [atom()]
  def replaceable_fields, do: @replaceable_fields

  @doc """
  Upsert a single file record without updating mtime.

  Used by the FileWatcher to keep role, ownership, and validation fresh
  in real-time while leaving mtime stale so `sync_changed` still picks
  up the file as changed during the stop hook validation pass.
  """
  @spec upsert_file_metadata(Scope.t(), map()) :: {:ok, File.t()} | {:error, term()}
  def upsert_file_metadata(%Scope{active_project_id: project_id} = scope, attrs) do
    now = NaiveDateTime.utc_now()

    entry =
      attrs
      |> Map.drop(@scanner_scratch)
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
    # `returning: true`, because what was deleted is the other half of a sync's
    # event list — embedding cleanup needs each removed row's role and path, and
    # reading them beforehand means loading the whole file table to find the few
    # that are gone.
    File
    |> where([f], f.project_id == ^project_id and f.path not in ^current_paths)
    |> scope_to_harness(scope)
    |> select([f], f)
    |> Repo.delete_all()
  end

  # `is_nil(f.working_copy_id)` is deliberately *not* matched when a harness is set:
  # a row owned by nobody is not this checkout's to delete, and leaving it makes
  # the state visible rather than quietly disappearing it.
  defp scope_to_harness(query, %Scope{active_working_copy_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_working_copy_id: working_copy_id}),
    do: where(query, [f], f.working_copy_id == ^working_copy_id)

  @doc """
  Every tracked path and when it was last modified, for this checkout.

  Two columns rather than the whole table. `FileSync.sync_changed/2` uses this
  to decide which files to *open* — a file whose mtime has not moved does not
  need reading or fingerprinting — and that is the only thing a sync still needs
  to know up front. Whether the content actually changed is decided by the
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

defmodule CodeMySpec.Problems.ProblemRepository do
  @moduledoc """
  Repository module providing scoped data access operations for problems.
  Handles database queries with proper scope filtering and user/project isolation.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Harnesses
  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  One cheap read answering "has anything changed, and is there anything to say".

  Returns `{count, latest_change}` for this working copy — a count and the most
  recent `updated_at` across its problems, in a single indexed query.

  Exists for `Hooks.AnalysisAlert`, which runs before every Read, Grep and Bash
  in the system. Loading problems to decide whether to stay silent would tax
  every tool call in every session for a message that fires twice a turn, and a
  check that makes everything feel slow is one somebody switches off.
  """
  @spec watermark(Scope.t()) :: {non_neg_integer(), DateTime.t() | nil}
  def watermark(%Scope{active_project_id: project_id} = scope) do
    Problem
    |> where([p], p.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> reject_superseded()
    |> select([p], {count(p.id), max(p.updated_at)})
    |> Repo.one()
  end

  @doc """
  Retrieves problems for the active project in scope, optionally filtered by source,
  source_type, file_path, category, or severity.

  ## Parameters

    * `scope` - The user scope with active project
    * `opts` - Keyword list of optional filters:
      - `:source` - Filter by source (e.g., "credo")
      - `:source_type` - Filter by source_type atom (e.g., :static_analysis, :test)
      - `:file_path` - Filter by file_path (supports SQL LIKE patterns with %)
      - `:category` - Filter by category string
      - `:severity` - Filter by severity atom (e.g., :error, :warning, :info)

  ## Examples

      iex> list_project_problems(scope, [])
      [%Problem{}, ...]

      iex> list_project_problems(scope, source: "credo", severity: :error)
      [%Problem{severity: :error, source: "credo"}, ...]

  """
  @spec list_project_problems(Scope.t(), keyword()) :: [Problem.t()]
  def list_project_problems(%Scope{active_project_id: project_id} = scope, opts) do
    Problem
    |> where([p], p.project_id == ^project_id)
    |> scope_to_harness(scope)
    |> reject_superseded()
    |> apply_filters(opts)
    |> order_by([p], [
      fragment(
        "CASE ? WHEN 'error' THEN 1 WHEN 'warning' THEN 2 WHEN 'info' THEN 3 END",
        p.severity
      ),
      asc: p.file_path,
      asc: p.line
    ])
    |> Repo.all()
  end

  @doc """
  Paginated list of problems for the active project, with severity ordering and
  source-based counts for filter chips.

  Options:
  - `:page` — 1-based page number (default `1`)
  - `:per_page` — page size (default `25`)
  - `:filter` — `:all` (default) or one of the source strings
    (`"credo"`, `"compiler"`, `"exunit"`, `"spex"`,
    `"spec_validation"`, `"qa_validation"`).
  - `:severity` — `:error`, `:warning` or `:info`. Omit for all.

  Severity narrows the scope before the counts are taken, so
  `counts_by_source` and `unfiltered_count` describe the same population the
  page does. A chip reading 26 above a page that can only ever show errors
  would be counting a different question than the one asked.
  """
  @spec list_problems_paginated(Scope.t(), keyword()) :: %{
          problems: [Problem.t()],
          page: pos_integer(),
          per_page: pos_integer(),
          total_count: non_neg_integer(),
          unfiltered_count: non_neg_integer(),
          counts_by_source: %{optional(String.t()) => non_neg_integer()},
          total_pages: pos_integer(),
          filter: :all | String.t()
        }
  def list_problems_paginated(%Scope{active_project_id: project_id} = scope, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = max(Keyword.get(opts, :per_page, 25), 1)
    filter = Keyword.get(opts, :filter, :all)

    project_scope =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> scope_to_harness(scope)
      |> apply_severity(Keyword.get(opts, :severity))

    unfiltered_count = Repo.aggregate(project_scope, :count, :id)

    counts_by_source =
      project_scope
      |> group_by([p], p.source)
      |> select([p], {p.source, count(p.id)})
      |> Repo.all()
      |> Map.new()

    base = apply_problem_filter(project_scope, filter)
    total_count = Repo.aggregate(base, :count, :id)
    total_pages = max(div(total_count + per_page - 1, per_page), 1)

    problems =
      base
      |> order_by([p], [
        fragment(
          "CASE ? WHEN 'error' THEN 1 WHEN 'warning' THEN 2 WHEN 'info' THEN 3 END",
          p.severity
        ),
        asc: p.source,
        asc: p.file_path,
        asc: p.line
      ])
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> preload(:component)
      |> Repo.all()

    %{
      problems: problems,
      page: page,
      per_page: per_page,
      total_count: total_count,
      unfiltered_count: unfiltered_count,
      counts_by_source: counts_by_source,
      total_pages: total_pages,
      filter: filter
    }
  end

  defp apply_severity(query, nil), do: query

  defp apply_severity(query, severity) when is_atom(severity),
    do: where(query, [p], p.severity == ^severity)

  defp apply_problem_filter(query, :all), do: query

  defp apply_problem_filter(query, source) when is_binary(source) do
    where(query, [p], p.source == ^source)
  end

  @doc """
  Stores a list of problems for the active project without clearing existing problems.

  Problems are inserted in a transaction. If any problem fails validation, the entire
  transaction is rolled back.

  ## Parameters

    * `scope` - The user scope with active project
    * `problems` - List of problem structs or maps with problem attributes

  ## Examples

      iex> create_problems(scope, [%{message: "Error 1", ...}])
      {:ok, [%Problem{}, ...]}

      iex> create_problems(scope, [%{invalid: "data"}])
      {:error, %Ecto.Changeset{}}

  """
  @spec create_problems(Scope.t(), [Problem.t() | map()]) ::
          {:ok, [Problem.t()]} | {:error, term()}
  def create_problems(_scope, []), do: {:ok, []}

  def create_problems(%Scope{} = scope, problems) when is_list(problems) do
    Repo.transaction(fn ->
      case insert_all_problems(problems, scope) do
        {:error, changeset} -> Repo.rollback(changeset)
        {:ok, inserted_problems} -> inserted_problems
      end
    end)
  end

  @doc """
  Performs atomic wipe-and-replace operation for project problems.
  Clears all existing problems for the project then stores the new set.

  This operation is performed in a transaction to ensure atomicity. If the insert
  fails, the delete is rolled back.

  ## Parameters

    * `scope` - The user scope with active project
    * `problems` - List of problem structs or maps with problem attributes

  ## Examples

      iex> replace_project_problems(scope, [%{message: "New error", ...}])
      {:ok, [%Problem{}, ...]}

      iex> replace_project_problems(scope, [])
      {:ok, []}

  """
  @spec replace_project_problems(Scope.t(), [Problem.t() | map()]) ::
          {:ok, [Problem.t()]} | {:error, term()}
  def replace_project_problems(%Scope{} = scope, problems)
      when is_list(problems) do
    Repo.transaction(fn ->
      delete_all_project_problems(scope)

      case insert_all_problems(problems, scope) do
        {:error, changeset} -> Repo.rollback(changeset)
        {:ok, inserted_problems} -> inserted_problems
      end
    end)
  end

  @doc """
  Atomically reconcile one source's problems: clear the source over the given
  file scope (`:all` or a path list), then insert the new set — all in a single
  transaction so an aborted caller can never strand a half-reconciled state
  (the stop-hook stranded-problems bug).

  ## Examples

      iex> reconcile_problems_for_source(scope, "exunit", :all, problems)
      {:ok, [%Problem{}, ...]}

      iex> reconcile_problems_for_source(scope, "exunit", ["test/a_test.exs"], [])
      {:ok, []}

  """
  @spec reconcile_problems_for_source(Scope.t(), String.t(), [String.t()] | :all, [
          Problem.t() | map()
        ]) :: {:ok, [Problem.t()]} | {:error, term()}
  def reconcile_problems_for_source(
        %Scope{} = scope,
        source,
        file_scope,
        problems
      )
      when is_binary(source) and is_list(problems) do
    Repo.transaction(fn ->
      clear_problems_for_source(scope, [source: source], file_scope)

      case insert_all_problems(problems, scope) do
        {:error, changeset} -> Repo.rollback(changeset)
        {:ok, inserted_problems} -> inserted_problems
      end
    end)
  end

  @doc """
  Atomically replaces problems for specific file paths within a project.

  Deletes all existing problems matching the given file paths, then inserts the new
  problems. Problems for other file paths in the project are left untouched.

  ## Parameters

    * `scope` - The user scope with active project
    * `file_paths` - List of file path strings whose problems should be replaced
    * `problems` - List of problem structs or maps with problem attributes to insert

  ## Examples

      iex> replace_problems_for_files(scope, ["lib/app/accounts.ex"], [%{message: "New", ...}])
      {:ok, [%Problem{}, ...]}

      iex> replace_problems_for_files(scope, ["lib/app/accounts.ex"], [])
      {:ok, []}

      iex> replace_problems_for_files(scope, [], problems)
      {:ok, []}

  """
  @spec replace_problems_for_files(Scope.t(), [String.t()], [Problem.t() | map()]) ::
          {:ok, [Problem.t()]} | {:error, term()}
  def replace_problems_for_files(_scope, [], _problems), do: {:ok, []}

  def replace_problems_for_files(
        %Scope{active_project_id: project_id} = scope,
        file_paths,
        problems
      )
      when is_list(file_paths) and is_list(problems) do
    Repo.transaction(fn ->
      Problem
      |> where([p], p.project_id == ^project_id and p.file_path in ^file_paths)
      |> scope_to_harness(scope)
      |> Repo.delete_all()

      case insert_all_problems(problems, scope) do
        {:error, changeset} -> Repo.rollback(changeset)
        {:ok, inserted_problems} -> inserted_problems
      end
    end)
  end

  @doc """
  Removes all problems for the active project in scope.

  ## Parameters

    * `scope` - The user scope with active project

  ## Examples

      iex> clear_project_problems(scope)
      {:ok, 5}

  """
  @spec clear_project_problems(Scope.t()) :: {:ok, integer()} | {:error, term()}
  def clear_project_problems(%Scope{} = scope) do
    count = delete_all_project_problems(scope)
    {:ok, count}
  end

  @doc """
  Clears problems matching a source filter for specific file paths within a project.

  Used for stale problem clearing: each validator clears only its own source's problems
  for the files it's about to re-check, preventing one validator from wiping another's results.

  ## Parameters

    * `scope` - The user scope with active project
    * `source_filter` - Keyword list with `:source` and/or `:source_type` filters
    * `file_paths` - List of file path strings whose matching problems should be cleared.
      Pass `:all` to clear matching problems project-wide (used for compiler errors).

  ## Examples

      iex> clear_problems_for_source(scope, [source: "credo"], ["lib/app.ex"])
      {:ok, 2}

      iex> clear_problems_for_source(scope, [source: "compiler"], :all)
      {:ok, 1}

  """
  @spec clear_problems_for_source(Scope.t(), keyword(), [String.t()] | :all) ::
          {:ok, integer()}
  def clear_problems_for_source(
        %Scope{active_project_id: project_id} = scope,
        source_filter,
        file_paths
      ) do
    query =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> scope_to_harness(scope)
      |> apply_source_filter(source_filter)
      |> apply_file_scope(file_paths)

    {count, _} = Repo.delete_all(query)
    {:ok, count}
  end

  @doc """
  Delete all problems whose `file_path` is not in the given list.

  Used during sync to clear problems for files that have been deleted from
  the project — those problems reference source paths that no longer exist.
  Problems with `file_path` nil or `"unknown"` are preserved: `"unknown"` is
  the placeholder for compiler errors recovered from raw output (no
  diagnostics file), and sweeping those away would un-block a stop that
  should stay blocked. They clear on the next full compiler reconcile.
  """
  @spec clear_problems_for_missing_files(Scope.t(), [String.t()]) :: {:ok, integer()}
  def clear_problems_for_missing_files(
        %Scope{active_project_id: project_id} = scope,
        current_paths
      )
      when is_list(current_paths) do
    {count, _} =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> scope_to_harness(scope)
      |> where([p], not is_nil(p.file_path) and p.file_path != "unknown")
      |> where([p], p.file_path not in ^current_paths)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Atomically replaces problems for specific components and source.

  Deletes existing problems matching `component_id IN component_ids AND source = source`,
  then inserts the new problems. Problems for other components or sources are untouched.
  """
  @spec replace_problems_for_components(Scope.t(), [binary()], String.t(), [Problem.t() | map()]) ::
          {:ok, [Problem.t()]} | {:error, term()}
  def replace_problems_for_components(_scope, [], _source, _problems), do: {:ok, []}

  def replace_problems_for_components(
        %Scope{active_project_id: project_id} = scope,
        component_ids,
        source,
        problems
      )
      when is_list(component_ids) and is_binary(source) do
    Repo.transaction(fn ->
      Problem
      |> where([p], p.project_id == ^project_id)
      |> where([p], p.component_id in ^component_ids)
      |> where([p], p.source == ^source)
      |> scope_to_harness(scope)
      |> Repo.delete_all()

      case insert_all_problems(problems, scope) do
        {:error, changeset} -> Repo.rollback(changeset)
        {:ok, inserted_problems} -> inserted_problems
      end
    end)
  end

  @doc """
  Deletes all problems for the given component IDs.
  """
  @spec delete_problems_for_components(Scope.t(), [binary()]) :: {:ok, integer()}
  def delete_problems_for_components(_scope, []), do: {:ok, 0}

  def delete_problems_for_components(%Scope{active_project_id: project_id}, component_ids)
      when is_list(component_ids) do
    {count, _} =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> where([p], p.component_id in ^component_ids)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns distinct component IDs that have at least one problem.
  Excludes problems with nil component_id.
  """
  @spec component_ids_with_problems(Scope.t()) :: [binary()]
  def component_ids_with_problems(%Scope{active_project_id: project_id}) do
    Problem
    |> where([p], p.project_id == ^project_id)
    |> where([p], not is_nil(p.component_id))
    |> select([p], p.component_id)
    |> distinct(true)
    |> Repo.all()
  end

  # Private helpers

  defp apply_source_filter(query, []), do: query

  defp apply_source_filter(query, [{:source, value} | rest]) do
    query |> where([p], p.source == ^value) |> apply_source_filter(rest)
  end

  defp apply_source_filter(query, [{:source_type, value} | rest]) do
    query |> where([p], p.source_type == ^value) |> apply_source_filter(rest)
  end

  defp apply_source_filter(query, [{:exclude_source, value} | rest]) do
    query |> where([p], p.source != ^value) |> apply_source_filter(rest)
  end

  defp apply_source_filter(query, [_ | rest]), do: apply_source_filter(query, rest)

  defp apply_file_scope(query, :all), do: query
  defp apply_file_scope(query, []), do: where(query, [_p], false)

  defp apply_file_scope(query, file_paths) when is_list(file_paths) do
    where(query, [p], p.file_path in ^file_paths)
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{filter, value} | rest]) do
    query
    |> apply_single_filter(filter, value)
    |> apply_filters(rest)
  end

  defp apply_single_filter(query, :source, value) do
    where(query, [p], p.source == ^value)
  end

  defp apply_single_filter(query, :sources, values) when is_list(values) do
    where(query, [p], p.source in ^values)
  end

  defp apply_single_filter(query, :source_type, value) do
    where(query, [p], p.source_type == ^value)
  end

  defp apply_single_filter(query, :file_path, value) do
    where(query, [p], like(p.file_path, ^value))
  end

  defp apply_single_filter(query, :category, value) do
    where(query, [p], p.category == ^value)
  end

  defp apply_single_filter(query, :severity, value) do
    where(query, [p], p.severity == ^value)
  end

  defp apply_single_filter(query, _unknown, _value), do: query

  defp to_attrs_map(%Problem{} = problem) do
    problem
    |> Map.from_struct()
    |> Map.drop([:__meta__, :project, :component])
  end

  defp to_attrs_map(attrs) when is_map(attrs), do: attrs

  defp delete_all_project_problems(%Scope{active_project_id: project_id} = scope) do
    {count, _} =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> scope_to_harness(scope)
      |> Repo.delete_all()

    count
  end

  # A reconcile is a wipe-and-replace for one source. Unscoped, one checkout's
  # analyzer run cleared the other's findings — the same shape as the file
  # corruption, one layer over. A scope with no harness clears across the
  # project, which is what a caller holding the project rather than a copy of it
  # means.
  # Hide a finding only when the file it describes has provably changed since it
  # was recorded — both fingerprints present and different.
  #
  # A reconcile replaces problems per source per file, so a finding survives any
  # run that does not re-examine its exact path, and is then reported against a
  # file that moved underneath it. That is how a credo finding came to be
  # reported at line 86 of an 83-line file, as a current result rather than a
  # stale one, with credo run by hand disagreeing.
  #
  # Deliberately conservative: a missing fingerprint on either side keeps the
  # problem. Everything else tonight went wrong by treating absent information
  # as good news, and hiding a real finding is worse than showing an old one.
  defp reject_superseded(query) do
    # The replacement run, not the edit, is what retires a finding.
    #
    # This used to hide a problem the moment its file's fingerprint moved on.
    # The row survived — supersession is a query-time filter, never a delete —
    # so the finding simply stopped being visible, and stopped blocking, before
    # any analyzer had looked at the new content. Story 988's criterion 8201 is
    # exactly that: "a finding from before the last edit still blocks until the
    # rerun lands". It did not; an edit was enough to clear the gate.
    #
    # That is also why it read as a plumbing bug for so long. Every input to the
    # blocking decision was correct — mode `:block_all`, one credo problem,
    # matching harness — and the problem was still there afterwards, which looks
    # like proof that supersession never fired. A filter that hides without
    # deleting leaves no evidence of having run.
    #
    # So the fingerprint difference is now a necessary condition rather than a
    # sufficient one: the analyzer must also have finished a run for that source
    # against the changed file. Once it has, reconciliation has already replaced
    # that source's set, so anything still standing was re-reported and belongs
    # on the gate anyway.
    reruns =
      from(r in CodeMySpec.Analysis.Run,
        where: r.source == parent_as(:problem).source,
        where: r.project_id == parent_as(:problem).project_id,
        where: r.status == :completed,
        where: not is_nil(r.finished_at),
        where: r.finished_at > parent_as(:file).mtime,
        select: 1
      )

    files =
      from(f in CodeMySpec.Files.File,
        as: :file,
        where: parent_as(:problem).file_path == f.path,
        where: parent_as(:problem).harness_id == f.harness_id,
        where: not is_nil(f.fingerprint),
        where: f.fingerprint != parent_as(:problem).file_fingerprint,
        where: not is_nil(f.mtime),
        where: exists(reruns),
        select: 1
      )

    query
    |> from(as: :problem)
    |> where([p], is_nil(p.file_fingerprint) or not exists(files))
  end

  # A scope that names no working copy means *the project's default one* — the
  # same thing it already meant on the way in, where `insert_all_problems/2`
  # sends such writes to `Harnesses.ensure_default/1`.
  #
  # It used to mean "every working copy" here, and that asymmetry was
  # destructive rather than merely wrong. `clear_problems_for_source/3` uses
  # this predicate, so one checkout reconciling credo under a scope with no
  # harness deleted every *other* checkout's credo problems and inserted its own
  # under the default. Demonstrated: two harnesses each holding one problem, a
  # third reconcile of a single problem, and both of the others were gone.
  #
  # The aftermath is what gets reported, because it does not look like a
  # deletion. A harness-scoped read returns nothing while an unscoped one still
  # shows a live project-wide count, so the stop hook's blocking set and its
  # advisory count describe different populations in one response — and the
  # findings it blocks on name files whose rows no longer exist.
  #
  # `default_id/1` is a pure function of the project id, so this costs a read
  # path nothing and creates no row.
  defp scope_to_harness(query, %Scope{active_harness_id: nil, active_project_id: project_id})
       when is_binary(project_id),
       do: where(query, [p], p.harness_id == ^Harnesses.default_id(project_id))

  defp scope_to_harness(query, %Scope{active_harness_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_harness_id: harness_id}),
    do: where(query, [p], p.harness_id == ^harness_id)

  defp insert_all_problems([], _scope), do: {:ok, []}

  defp insert_all_problems(problems, %Scope{active_project_id: project_id} = scope) do
    # Resolved once rather than per problem: a reconcile inserts hundreds, and
    # `ensure_default/1` is a write. A writer that named its working copy gets
    # that one; one that did not shares the project's nil object, same as files.
    harness_id = scope.active_harness_id || Harnesses.ensure_default(scope)

    # Likewise once: which version of each file these were found in, so a
    # finding that outlives its file can later be recognised as superseded.
    fingerprints = fingerprints_for(project_id, harness_id, problems)

    problems
    |> Enum.reduce_while([], fn problem_data, acc ->
      case insert_single_problem(problem_data, project_id, harness_id, fingerprints) do
        {:ok, problem} -> {:cont, [problem | acc]}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:error, _changeset} = error -> error
      inserted_problems -> {:ok, Enum.reverse(inserted_problems)}
    end
  end

  # One query for the whole batch — a reconcile inserts hundreds, and per-problem
  # lookups would be hundreds of round trips for data that does not change
  # inside a single reconcile.
  defp fingerprints_for(project_id, harness_id, problems) do
    paths =
      problems
      |> Enum.map(&problem_path/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    CodeMySpec.Files.File
    |> where([f], f.project_id == ^project_id and f.harness_id == ^harness_id)
    |> where([f], f.path in ^paths)
    |> select([f], {f.path, f.fingerprint})
    |> Repo.all()
    |> Map.new()
  end

  defp problem_path(%{file_path: path}) when is_binary(path), do: path
  defp problem_path(%{"file_path" => path}) when is_binary(path), do: path
  defp problem_path(_), do: nil

  defp insert_single_problem(problem_data, project_id, harness_id, fingerprints) do
    attrs = problem_data |> to_attrs_map() |> Map.put(:project_id, project_id)
    fingerprint = Map.get(fingerprints, attrs[:file_path] || attrs["file_path"])

    attrs =
      attrs
      |> Map.put(:harness_id, harness_id)
      |> Map.put(:file_fingerprint, fingerprint)

    %Problem{}
    |> Problem.changeset(attrs)
    |> Repo.insert()
  end
end

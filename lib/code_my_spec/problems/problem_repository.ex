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
  def list_project_problems(%Scope{active_project_id: project_id}, opts) do
    Problem
    |> where([p], p.project_id == ^project_id)
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
  def list_problems_paginated(%Scope{active_project_id: project_id}, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = max(Keyword.get(opts, :per_page, 25), 1)
    filter = Keyword.get(opts, :filter, :all)

    project_scope = where(Problem, [p], p.project_id == ^project_id)
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
  defp scope_to_harness(query, %Scope{active_harness_id: nil}), do: query

  defp scope_to_harness(query, %Scope{active_harness_id: harness_id}),
    do: where(query, [p], p.harness_id == ^harness_id)

  defp insert_all_problems([], _scope), do: {:ok, []}

  defp insert_all_problems(problems, %Scope{active_project_id: project_id} = scope) do
    # Resolved once rather than per problem: a reconcile inserts hundreds, and
    # `ensure_default/1` is a write. A writer that named its working copy gets
    # that one; one that did not shares the project's nil object, same as files.
    harness_id = scope.active_harness_id || Harnesses.ensure_default(scope)

    problems
    |> Enum.reduce_while([], fn problem_data, acc ->
      case insert_single_problem(problem_data, project_id, harness_id) do
        {:ok, problem} -> {:cont, [problem | acc]}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:error, _changeset} = error -> error
      inserted_problems -> {:ok, Enum.reverse(inserted_problems)}
    end
  end

  defp insert_single_problem(problem_data, project_id, harness_id) do
    attrs =
      problem_data
      |> to_attrs_map()
      |> Map.put(:project_id, project_id)
      |> Map.put(:harness_id, harness_id)

    %Problem{}
    |> Problem.changeset(attrs)
    |> Repo.insert()
  end
end

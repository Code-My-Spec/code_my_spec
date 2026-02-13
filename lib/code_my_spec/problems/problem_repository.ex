defmodule CodeMySpec.Problems.ProblemRepository do
  @moduledoc """
  Repository module providing scoped data access operations for problems.
  Handles database queries with proper scope filtering and user/project isolation.
  """

  import Ecto.Query, warn: false

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

  def create_problems(%Scope{active_project_id: project_id}, problems) when is_list(problems) do
    Repo.transaction(fn ->
      case insert_all_problems(problems, project_id) do
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
  def replace_project_problems(%Scope{active_project_id: project_id}, problems)
      when is_list(problems) do
    Repo.transaction(fn ->
      delete_all_project_problems(project_id)

      case insert_all_problems(problems, project_id) do
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

  def replace_problems_for_files(%Scope{active_project_id: project_id}, file_paths, problems)
      when is_list(file_paths) and is_list(problems) do
    Repo.transaction(fn ->
      Problem
      |> where([p], p.project_id == ^project_id and p.file_path in ^file_paths)
      |> Repo.delete_all()

      case insert_all_problems(problems, project_id) do
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
  def clear_project_problems(%Scope{active_project_id: project_id}) do
    count = delete_all_project_problems(project_id)
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
  def clear_problems_for_source(%Scope{active_project_id: project_id}, source_filter, file_paths) do
    query =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> apply_source_filter(source_filter)
      |> apply_file_scope(file_paths)

    {count, _} = Repo.delete_all(query)
    {:ok, count}
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
    |> Map.drop([:__meta__, :project])
  end

  defp to_attrs_map(attrs) when is_map(attrs), do: attrs

  defp delete_all_project_problems(project_id) do
    {count, _} =
      Problem
      |> where([p], p.project_id == ^project_id)
      |> Repo.delete_all()

    count
  end

  defp insert_all_problems([], _project_id), do: {:ok, []}

  defp insert_all_problems(problems, project_id) do
    problems
    |> Enum.reduce_while([], fn problem_data, acc ->
      case insert_single_problem(problem_data, project_id) do
        {:ok, problem} -> {:cont, [problem | acc]}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:error, _changeset} = error -> error
      inserted_problems -> {:ok, Enum.reverse(inserted_problems)}
    end
  end

  defp insert_single_problem(problem_data, project_id) do
    attrs =
      problem_data
      |> to_attrs_map()
      |> Map.put(:project_id, project_id)

    %Problem{}
    |> Problem.changeset(attrs)
    |> Repo.insert()
  end
end

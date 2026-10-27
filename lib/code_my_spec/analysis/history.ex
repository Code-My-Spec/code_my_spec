defmodule CodeMySpec.Analysis.History do
  @moduledoc """
  Retained findings for analyzer runs. A full completed test run also records
  passes implicitly: a test absent from its failures passed in that run.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Analysis.History.Finding
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @default_retention_days 30

  @doc "Record the problems reported by a completed run without changing current Problems."
  @spec record!(Run.t(), [CodeMySpec.Problems.Problem.t()]) :: :ok
  def record!(%Run{id: run_id, status: :completed}, problems) when is_list(problems) do
    {:ok, _} =
      Repo.transaction(fn ->
        Finding
        |> where([f], f.run_id == ^run_id)
        |> Repo.delete_all()

        Enum.each(problems, fn problem ->
          problem
          |> Finding.from_problem(run_id)
          |> Repo.insert!()
        end)
      end)

    :ok
  end

  @doc "All findings retained for a run in the active project."
  @spec findings(Scope.t(), Run.t() | integer()) :: [Finding.t()]
  def findings(%Scope{active_project_id: project_id}, %Run{id: id}),
    do: findings_for(project_id, id)

  def findings(%Scope{active_project_id: project_id}, id) when is_integer(id),
    do: findings_for(project_id, id)

  defp findings_for(project_id, id) do
    Finding
    |> join(:inner, [f], r in Run, on: r.id == f.run_id)
    |> where([f, r], r.project_id == ^project_id and r.id == ^id)
    |> order_by([f], asc: f.id)
    |> Repo.all()
  end

  @doc "Test failures retained for a run in the active project."
  @spec failures(Scope.t(), Run.t() | integer()) :: [Finding.t()]
  def failures(%Scope{} = scope, run),
    do: scope |> findings(run) |> Enum.filter(&(&1.category == "test_failure"))

  @doc "Whether a completed full run at the commit omitted this test from failures."
  @spec passed?(Scope.t(), String.t(), String.t(), String.t()) :: boolean()
  def passed?(%Scope{active_project_id: project_id}, commit, file_path, test_name)
      when is_binary(commit) and is_binary(file_path) and is_binary(test_name) do
    source = source_for(file_path)

    from(r in Run, as: :run)
    |> where(
      [r],
      r.project_id == ^project_id and r.source == ^source and
        r.kind == :full and r.status == :completed and
        r.start_commit == ^commit and r.completed_commit == ^commit and
        r.start_tree_dirty == false
    )
    |> where(
      [r],
      not exists(
        from f in Finding,
          where:
            f.run_id == parent_as(:run).id and f.category == "test_failure" and
              f.file_path == ^file_path and f.test_name == ^test_name
      )
    )
    |> Repo.exists?()
  end

  defp source_for("test/spex/" <> _path), do: "spex"
  defp source_for("test/" <> _path), do: "exunit"

  @doc "Retention period read at prune time; configuration may change without recompiling."
  @spec retention_days() :: pos_integer()
  def retention_days do
    days =
      :code_my_spec
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:retention_days, @default_retention_days)

    case days do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "invalid analysis history retention_days: #{inspect(value)}"
    end
  end

  @doc "Prune expired finished runs and their findings for the active project."
  @spec prune(Scope.t()) :: {:ok, non_neg_integer()}
  def prune(%Scope{active_project_id: project_id}) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days(), :day)

    {count, _} =
      Run
      |> where([r], r.project_id == ^project_id)
      |> where([r], r.status in [:completed, :failed, :superseded, :cancelled])
      |> where([r], r.finished_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end
end

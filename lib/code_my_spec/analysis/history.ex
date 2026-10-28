defmodule CodeMySpec.Analysis.History do
  @moduledoc """
  Retained findings for completed analyzer runs.

  Each run owns a snapshot of its failures and problems. Deleting an expired
  run deletes that snapshot with it; the current per-copy Problems list is
  independent of history.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @default_retention_days 30
  @terminal_statuses [:completed, :failed, :superseded, :cancelled, :abandoned]

  @doc "Retention window in days, configured with `:analysis_retention_days`."
  @spec retention_days() :: pos_integer()
  def retention_days do
    case Application.get_env(:code_my_spec, :analysis_retention_days, @default_retention_days) do
      days when is_integer(days) and days > 0 ->
        days

      value ->
        raise ArgumentError, "analysis_retention_days must be positive, got: #{inspect(value)}"
    end
  end

  @doc "Store the findings observed by one finished run without changing current Problems."
  @spec record!(Run.t(), [map()], [map() | struct()]) :: Run.t()
  def record!(%Run{status: status} = run, failures, problems)
      when status in [:completed, :failed] and is_list(failures) and is_list(problems) do
    findings = %{
      "failures" => Enum.map(failures, &plain_map/1),
      "problems" => Enum.map(problems, &problem_map/1)
    }

    run
    |> Ecto.Changeset.change(findings: findings)
    |> Repo.update!()
  end

  @doc "List retained runs for the active project, optionally filtered by source."
  @spec list(Scope.t(), keyword()) :: [map()]
  def list(%Scope{active_project_id: project_id}, opts \\ []) do
    source = Keyword.get(opts, :source)

    Run
    |> where([r], r.project_id == ^project_id and r.status in ^@terminal_statuses)
    |> maybe_source(source)
    |> order_by([r], desc: r.finished_at, desc: r.id)
    |> Repo.all()
    |> Enum.map(&as_history_entry/1)
  end

  @doc "Remove terminal runs older than the configured window, with their findings."
  @spec prune(Scope.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def prune(%Scope{active_project_id: project_id}, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -retention_days(), :day)

    {count, _} =
      Run
      |> where([r], r.project_id == ^project_id and r.status in ^@terminal_statuses)
      |> where([r], not is_nil(r.finished_at) and r.finished_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc "Whether the latest full exunit run at a commit observed this test passing."
  @spec test_passed?(Scope.t(), String.t(), String.t(), String.t()) :: boolean()
  def test_passed?(%Scope{active_project_id: project_id}, commit, file, name)
      when is_binary(commit) and is_binary(file) and is_binary(name) do
    Run
    |> where([r], r.project_id == ^project_id and r.source == "exunit")
    |> where([r], r.kind == :full and r.status == :completed and r.completed_commit == ^commit)
    |> order_by([r], desc: r.finished_at, desc: r.id)
    |> limit(1)
    |> Repo.one()
    |> passed_in_run?(file, name)
  end

  defp passed_in_run?(nil, _file, _name), do: false
  defp passed_in_run?(%Run{findings: nil}, _file, _name), do: false

  defp passed_in_run?(%Run{} = run, file, name) do
    run
    |> failures()
    |> Enum.any?(fn failure -> failure["file"] == file and failure["name"] == name end)
    |> Kernel.not()
  end

  defp maybe_source(query, nil), do: query

  defp maybe_source(query, source) when is_binary(source),
    do: where(query, [r], r.source == ^source)

  defp as_history_entry(%Run{} = run) do
    %{
      run_id: run.id,
      status: run.status,
      completed_commit: run.completed_commit,
      commit: run.completed_commit || run.start_commit,
      working_copy_id: run.working_copy_id,
      source: run.source,
      partial: run.kind == :partial,
      clean: run.start_tree_dirty == false,
      findings_recorded: not is_nil(run.findings),
      started_at: run.started_at,
      finished_at: run.finished_at,
      failures: failures(run),
      problems: Map.get(run.findings || %{}, "problems", [])
    }
  end

  defp failures(%Run{} = run), do: Map.get(run.findings || %{}, "failures", [])

  defp problem_map(%{__struct__: _} = problem) do
    problem
    |> Map.from_struct()
    |> Map.take([:severity, :source, :file_path, :line, :message, :category, :rule, :metadata])
    |> plain_map()
  end

  defp problem_map(problem) when is_map(problem), do: plain_map(problem)

  defp plain_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), plain_value(value)} end)
  end

  defp plain_value(nil), do: nil
  defp plain_value(value) when is_atom(value), do: Atom.to_string(value)
  defp plain_value(value) when is_map(value), do: plain_map(value)
  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  defp plain_value(value), do: value
end

defmodule CodeMySpec.Analysis.Tools.GetAnalysisHistory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis.History
  alias CodeMySpec.Tools

  @impl true
  def name, do: "get_analysis_history"

  @impl true
  def description, do: "Read completed analyzer runs with their retained failures and problems."

  @impl true
  def params do
    %{source: {:meta, :string, [description: "Optional analyzer source filter."]}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      {:ok, Jason.encode!(history_result(scope, params))}
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, scope} <- Tools.project_scope(context) do
      {:ok, history_result(scope, params)}
    end
  end

  defp history_result(scope, params) do
    runs =
      scope
      |> History.list(source: params[:source])
      |> Enum.map(&plain_run/1)

    %{runs: runs}
  end

  defp plain_run(run) do
    %{
      run_id: run.run_id,
      commit: run.commit,
      working_copy_id: run.working_copy_id,
      source: run.source,
      partial: run.partial,
      started_at: timestamp(run.started_at),
      finished_at: timestamp(run.finished_at),
      failures: run.failures,
      problems: run.problems
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end

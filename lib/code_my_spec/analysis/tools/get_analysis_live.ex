defmodule CodeMySpec.Analysis.Tools.GetAnalysisLive do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run

  # Enough to act on; the rest is in the run's page and its output.
  @shown 20

  @impl true
  def name, do: "get_analysis_live"

  @impl true
  def description do
    """
    What an analysis run is doing now: its state, the files it is in, test counts,
    failures and findings so far, and how long since it last reported.

    Supply run_id, or source for the latest compiler, credo, exunit or spex run in
    this working copy. `live` is "no_events" (queued, or running and not yet
    reporting), "streaming", "finished" (it reported its end), or "not_retained"
    (no live record for this run; read get_analysis_output). `seconds_since_event`
    tells a stalled run from a slow one. `status` is queued, running, completed,
    failed, cancelled or superseded. An orphaned failed run is shown as abandoned
    with a harness disconnect reason. Retained stdout is get_analysis_output's, not this.

    A queued run also carries queued_seconds and harness_connected: false there
    means nothing able to run it is reachable for this working copy right now.
    """
  end

  @impl true
  def params do
    %{
      run_id: {:meta, :integer, [description: "Run ID. Supply this or source, not both."]},
      source:
        {:meta, :string, [description: "Select the latest compiler, credo, exunit, or spex run."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, live} <- fetch(params, context), do: {:ok, Jason.encode!(live)}
  end

  @impl true
  def script_result(params, context) do
    with {:ok, live} <- fetch(params, context) do
      {:ok, Jason.decode!(Jason.encode!(live))}
    end
  end

  defp fetch(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         :ok <- working_copy(scope),
         {:ok, selector} <- selector(params),
         %Run{} = run <- Analysis.output_run(scope, selector) do
      {:ok, describe(run, Analysis.live_state(run.id), DateTime.utc_now())}
    else
      nil -> {:error, "No run matches in this working copy."}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  @doc false
  # Public so the shape can be checked against a run and a live record without
  # a running analyzer.
  def describe(run, live, now) do
    run
    |> ledger()
    |> Map.merge(live_part(run, live, now))
  end

  defp display_status(%Run{orphaned: true, status: :failed}), do: "abandoned"

  defp display_status(%Run{} = run) do
    if Run.queued?(run), do: "queued", else: to_string(run.status)
  end

  defp ledger(run) do
    Map.merge(
      %{
        run_id: run.id,
        source: run.source,
        status: display_status(run),
        orphaned: run.orphaned,
        reason: if(run.orphaned, do: "harness disconnected", else: nil),
        exit_status: run.exit_status,
        start_commit: run.start_commit,
        began_at: run.began_at,
        finished_at: run.finished_at
      },
      Analysis.queue_wait(run) || %{}
    )
  end

  defp live_part(%Run{} = run, nil, _now) do
    if Run.queued?(run) do
      %{live: "no_events"}
    else
      %{live: "not_retained", hint: "Read get_analysis_output for retained output."}
    end
  end

  defp live_part(_run, live, now) do
    failures = Enum.filter(live.tests, &(&1.state == "failed"))

    %{
      live: live_label(live),
      running_files: live.running_files,
      tests: %{
        reported: length(live.tests),
        passed: Enum.count(live.tests, &(&1.state == "passed")),
        failed: length(failures),
        skipped: Enum.count(live.tests, &(&1.state == "skipped"))
      },
      failures: Enum.take(failures, @shown),
      findings: Enum.take(live.findings, @shown),
      findings_count: length(live.findings),
      totals: live.totals,
      last_event_at: live.last_event_at,
      seconds_since_event: since(live.last_event_at, now)
    }
  end

  defp live_label(%{finished?: true}), do: "finished"
  defp live_label(%{last_event_at: nil}), do: "no_events"
  defp live_label(_live), do: "streaming"

  defp since(nil, _now), do: nil
  defp since(at, now), do: DateTime.diff(now, at)

  defp working_copy(%{active_working_copy_id: id}) when is_binary(id), do: :ok
  defp working_copy(_scope), do: {:error, "Select a working copy before reading a run."}

  defp selector(params) do
    case {params[:run_id], params[:source]} do
      {id, nil} when is_integer(id) and id > 0 -> {:ok, {:id, id}}
      {nil, source} when is_binary(source) -> source_selector(source)
      _ -> {:error, "Supply exactly one positive run_id or analyzer source."}
    end
  end

  defp source_selector(source) do
    if source in Run.sources(),
      do: {:ok, {:source, source}},
      else: {:error, "Unknown analyzer source."}
  end
end

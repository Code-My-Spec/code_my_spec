defmodule CodeMySpec.Analysis.StuckWork do
  @moduledoc """
  Reconciles analysis and promotion work in a time window and identifies open
  items whose duration or silence exceeds the configured limits.

  `snapshot/2` only reads the ledger. `check/2` additionally reports newly
  stuck items to the project's main agent at most once per reporting interval.
  """

  import Ecto.Query

  alias CodeMySpec.Analysis.{LiveRuns, Run}
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @defaults [
    window_hours: 24,
    duration_multiplier: 2,
    silence_minutes: 5,
    reporting_interval_minutes: 10
  ]
  @run_terminal [:completed, :failed, :superseded, :cancelled]
  @entry_terminal [:landed, :ejected, :cancelled]

  @type tally :: %{
          started: non_neg_integer(),
          finished: non_neg_integer(),
          open: non_neg_integer(),
          oldest_open_minutes: non_neg_integer() | nil
        }

  @doc "The window's counts and currently stuck work, scoped to one project."
  @spec snapshot(Scope.t(), keyword()) :: map()
  def snapshot(%Scope{active_project_id: project_id}, opts \\ []) when is_binary(project_id) do
    config = config(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -config.window_hours * 3600, :second)

    runs = Repo.all(from r in Run, where: r.project_id == ^project_id and r.started_at >= ^since)

    entries =
      Repo.all(from e in Entry, where: e.project_id == ^project_id and e.inserted_at >= ^since)

    history = run_history(project_id, now)

    %{
      runs:
        runs
        |> Enum.filter(&open_run?/1)
        |> Enum.map(&describe_run(&1, history, now, config))
        |> Enum.filter(&(&1.status == "stuck")),
      entries:
        entries
        |> Enum.filter(&open_entry?/1)
        |> Enum.map(&describe_entry(&1, now, config))
        |> Enum.filter(&(&1.status == "stuck")),
      analysis: tally(runs, & &1.started_at, &open_run?/1, now),
      promotion: tally(entries, & &1.inserted_at, &open_entry?/1, now)
    }
  end

  @doc "Read stuck work and notify Main when an item's reporting interval has elapsed."
  @spec check(Scope.t(), keyword()) :: map()
  def check(%Scope{} = scope, opts \\ []) do
    report = snapshot(scope, opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    interval = config(opts).reporting_interval_minutes * 60

    Enum.each(report.runs, &report_item(scope, :run, &1, now, interval))
    Enum.each(report.entries, &report_item(scope, :entry, &1, now, interval))
    report
  end

  @doc "True when the duration exceeds the historical limit or the event silence reaches its limit."
  @spec stuck?(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          number(),
          pos_integer()
        ) :: boolean()
  def stuck?(age, silence, p90, multiplier, silence_limit)
      when age >= 0 and silence >= 0 and is_number(multiplier) and multiplier > 0 and
             is_integer(silence_limit) and silence_limit > 0 do
    silence >= silence_limit or duration_stuck?(age, p90, multiplier)
  end

  defp duration_stuck?(age, p90, multiplier) when is_integer(p90) and p90 > 0,
    do: age > p90 * multiplier

  defp duration_stuck?(_age, nil, _multiplier), do: false

  defp config(opts) do
    :code_my_spec
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(opts)
    |> then(&Keyword.merge(@defaults, &1))
    |> validate_config()
  end

  defp validate_config(config) do
    Enum.each([:window_hours, :silence_minutes, :reporting_interval_minutes], fn key ->
      value = Keyword.fetch!(config, key)

      unless is_integer(value) and value > 0,
        do: raise(ArgumentError, "invalid #{key}: #{inspect(value)}")
    end)

    multiplier = Keyword.fetch!(config, :duration_multiplier)

    unless is_number(multiplier) and multiplier > 0,
      do: raise(ArgumentError, "invalid duration_multiplier: #{inspect(multiplier)}")

    Map.new(config)
  end

  defp run_history(project_id, now) do
    since = DateTime.add(now, -86_400, :second)

    Repo.all(
      from r in Run,
        where:
          r.project_id == ^project_id and r.finished_at >= ^since and
            r.status in [:completed, :failed],
        select: {r.source, r.began_at, r.started_at, r.finished_at}
    )
    |> Enum.group_by(fn {source, _, _, _} -> source end, fn {_, began, started, finished} ->
      max(DateTime.diff(finished, began || started), 1)
    end)
    |> Map.new(fn {source, durations} -> {source, percentile(durations, 90)} end)
  end

  @doc "Nearest rank percentile of observed durations, or nil with no history."
  @spec percentile([pos_integer()], 1..100) :: pos_integer() | nil
  def percentile([], _percent), do: nil

  def percentile(values, percent) when is_list(values) and percent in 1..100 do
    ordered = Enum.sort(values)
    Enum.at(ordered, max(ceil(length(ordered) * percent / 100) - 1, 0))
  end

  defp describe_run(run, history, now, config) do
    last_event =
      case LiveRuns.get(run.id) do
        %{last_event_at: %DateTime{} = at} -> at
        _ -> run.began_at || run.started_at
      end

    age = max(DateTime.diff(now, run.started_at), 0)
    silence = max(DateTime.diff(now, last_event), 0)

    stuck =
      stuck?(
        age,
        silence,
        Map.get(history, run.source),
        config.duration_multiplier,
        config.silence_minutes * 60
      )

    %{
      run_id: run.id,
      source: run.source,
      working_copy_id: run.working_copy_id,
      status: label(stuck),
      age_seconds: age,
      age_minutes: div(age, 60),
      last_event_at: last_event,
      seconds_since_event: silence
    }
  end

  defp describe_entry(entry, now, config) do
    age = max(DateTime.diff(now, entry.inserted_at), 0)
    silence = max(DateTime.diff(now, entry.updated_at || entry.inserted_at), 0)
    stuck = stuck?(age, silence, nil, config.duration_multiplier, config.silence_minutes * 60)

    %{
      entry_id: entry.id,
      working_copy_id: entry.working_copy_id,
      status: label(stuck),
      age_seconds: age,
      age_minutes: div(age, 60),
      last_event_at: entry.updated_at || entry.inserted_at,
      seconds_since_event: silence
    }
  end

  defp label(true), do: "stuck"
  defp label(false), do: "open"
  defp open_run?(%Run{status: :running, finished_at: nil}), do: true
  defp open_run?(%Run{status: status}) when status in @run_terminal, do: false
  defp open_run?(%Run{}), do: false
  defp open_entry?(%Entry{status: status}) when status in @entry_terminal, do: false
  defp open_entry?(%Entry{status: status}) when status in [:queued, :gating], do: true

  defp tally(items, started_at, open?, now) do
    open = Enum.filter(items, open?)

    oldest =
      open
      |> Enum.map(started_at)
      |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)

    %{
      started: length(items),
      finished: length(items) - length(open),
      open: length(open),
      oldest_open_minutes: oldest_age(oldest, now)
    }
  end

  defp oldest_age(nil, _now), do: nil
  defp oldest_age(at, now), do: max(div(DateTime.diff(now, at), 60), 0)

  defp report_item(scope, kind, item, now, interval) do
    :telemetry.execute(
      [:code_my_spec, :analysis, :stuck_work],
      %{},
      %{scope: scope, kind: kind, item: item, now: now, interval: interval}
    )
  end
end

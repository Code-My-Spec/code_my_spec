defmodule CodeMySpec.PromotionQueue.Timings do
  @moduledoc """
  Promotion stage durations and outcome summaries. A stage absent from the
  recorded timeline was not run; a recorded zero is a completed stage.

  Queue stage boundaries and the gate's analyzer run IDs are kept in the
  entry's `result["timing"]`. Only those IDs can contribute analyzer time.
  """

  import Ecto.Query

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo

  @stages ~w(queue-wait gate-build compiler credo exunit spex asset-build landing)
  @analyzers ~w(compiler credo exunit spex)
  @gate_stages ~w(gate-build compiler credo exunit spex asset-build)
  @windows %{"24h" => 86_400, "7d" => 604_800}

  @type stage :: %{status: :ran | :not_run, duration_seconds: non_neg_integer() | nil}
  @type timing :: %{
          id: Ecto.UUID.t(),
          completed_at: DateTime.t(),
          outcome: :landed | :ejected,
          stages: %{String.t() => stage()},
          analyzer_waits: %{String.t() => stage()},
          test_timings: [map()],
          file_timings: [map()],
          selection: map(),
          total_seconds: non_neg_integer(),
          gate_seconds: non_neg_integer()
        }

  @doc "The fixed display order for every promotion stage."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc "Read one completed promotion in a project, or nil when it is absent."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: timing() | nil
  def get(project_id, entry_id) when is_binary(project_id) and is_binary(entry_id) do
    Repo.one(from e in Entry, where: e.project_id == ^project_id and e.id == ^entry_id)
    |> load_timing()
  end

  @doc "Read one completed promotion using its already loaded entry."
  @spec for_entry(Entry.t()) :: timing() | nil
  def for_entry(%Entry{} = entry), do: load_timing(entry)

  @doc "Summarize completed promotions by outcome in the last 24 hours or seven days."
  @spec summary(Ecto.UUID.t(), String.t()) :: map()
  def summary(project_id, window \\ "24h")

  def summary(project_id, window) when is_binary(project_id) and is_map_key(@windows, window) do
    project_id |> list(window) |> summarize(window)
  end

  @doc "Completed promotion timings in a project's selected window."
  @spec list(Ecto.UUID.t(), String.t()) :: [timing()]
  def list(project_id, window \\ "24h")

  def list(project_id, window) when is_binary(project_id) and is_map_key(@windows, window) do
    since = DateTime.add(DateTime.utc_now(), -Map.fetch!(@windows, window), :second)

    entries =
      Repo.all(
        from e in Entry,
          where:
            e.project_id == ^project_id and e.status in [:landed, :ejected] and
              e.updated_at >= ^since,
          order_by: [asc: e.updated_at, asc: e.id]
      )

    Enum.map(entries, &load_timing/1) |> Enum.reject(&is_nil/1)
  end

  @doc "Build the shared page and tool figures from completed timings."
  @spec summarize([timing()], String.t()) :: map()
  def summarize(timings, window \\ "24h")
      when is_list(timings) and is_map_key(@windows, window) do
    outcomes = %{
      "landed" => summarize_outcome(timings, :landed),
      "ejected" => summarize_outcome(timings, :ejected)
    }

    %{
      "window" => window,
      "count" => length(timings),
      "empty" => timings == [],
      "outcomes" => outcomes,
      "promotions" => Enum.map(timings, &selection_summary/1),
      "miss_count" =>
        Enum.sum(Enum.map(timings, &length((Map.get(&1, :selection) || %{})["misses"] || []))),
      "slowest_tests" => slowest(timings, :test_timings),
      "slowest_files" => slowest(timings, :file_timings)
    }
  end

  @doc "Construct a timing from a queue entry and its explicitly associated gate runs."
  @spec build(Entry.t(), [Run.t()]) :: timing() | nil
  def build(%Entry{status: outcome} = entry, runs)
      when outcome in [:landed, :ejected] and is_list(runs) do
    recorded = get_in(entry.result || %{}, ["timing", "stages"]) || %{}
    run_ids = get_in(entry.result || %{}, ["timing", "run_ids"]) || []

    own_runs =
      Enum.filter(runs, fn
        %Run{id: id, kind: :full, working_copy_id: gate_id} ->
          id in run_ids and gate_id == get_in(entry.result || %{}, ["timing", "gate_copy_id"])

        _ ->
          false
      end)

    stages = Map.new(@stages, fn stage -> {stage, stage_value(stage, recorded, own_runs)} end)

    analyzer_waits =
      Map.new(@analyzers, fn source -> {source, analyzer_wait(source, own_runs)} end)

    wait_seconds = sum_stages(analyzer_waits, @analyzers)

    %{
      id: entry.id,
      completed_at: entry.updated_at,
      outcome: outcome,
      stages: stages,
      analyzer_waits: analyzer_waits,
      test_timings: timed_items(own_runs, "tests"),
      file_timings: timed_items(own_runs, "files"),
      selection: Map.get(entry.result || %{}, "test_selection", %{}),
      total_seconds: sum_stages(stages, @stages) + wait_seconds,
      gate_seconds: sum_stages(stages, @gate_stages) + wait_seconds
    }
  end

  def build(%Entry{}, _runs), do: nil

  defp selection_summary(timing) do
    selection = Map.get(timing, :selection) || %{}
    selected = selection["selected_tests"] || []
    suite_size = selection["suite_size"] || 0

    %{
      "id" => Map.get(timing, :id),
      "selected_share_percent" =>
        if(suite_size > 0, do: 100 * length(selected) / suite_size, else: nil),
      "selection" => selection
    }
  end

  defp load_timing(nil), do: nil

  defp load_timing(%Entry{status: status} = entry) when status in [:landed, :ejected] do
    ids = get_in(entry.result || %{}, ["timing", "run_ids"]) || []

    runs =
      case ids do
        [] -> []
        _ -> Repo.all(from r in Run, where: r.id in ^ids and r.project_id == ^entry.project_id)
      end

    build(entry, runs)
  end

  defp load_timing(%Entry{}), do: nil

  defp stage_value(stage, _recorded, runs) when stage in @analyzers do
    case Enum.find(runs, &(&1.source == stage)) do
      %Run{began_at: %DateTime{} = began, finished_at: %DateTime{} = finished} ->
        ran(seconds(began, finished))

      _ ->
        not_run()
    end
  end

  defp stage_value(stage, recorded, _runs), do: recorded_stage(recorded, stage)

  defp analyzer_wait(source, runs) do
    case Enum.find(runs, &(&1.source == source)) do
      %Run{started_at: %DateTime{} = requested, began_at: %DateTime{} = began} ->
        ran(seconds(requested, began))

      _ ->
        not_run()
    end
  end

  defp recorded_stage(recorded, stage) do
    case Map.fetch(recorded, stage) do
      {:ok, seconds} when is_integer(seconds) and seconds >= 0 ->
        ran(seconds)

      {:ok, %{"duration_seconds" => seconds}} when is_integer(seconds) and seconds >= 0 ->
        ran(seconds)

      {:ok, %{"started_at" => started, "finished_at" => finished}}
      when is_binary(started) and is_binary(finished) ->
        with {:ok, start_time, _} <- DateTime.from_iso8601(started),
             {:ok, finish_time, _} <- DateTime.from_iso8601(finished),
             :gt <- DateTime.compare(finish_time, start_time) do
          ran(seconds(start_time, finish_time))
        else
          :eq -> ran(0)
          _ -> not_run()
        end

      _ ->
        not_run()
    end
  end

  defp seconds({:ok, started, _}, {:ok, finished, _}), do: seconds(started, finished)

  defp seconds(%DateTime{} = started, %DateTime{} = finished),
    do: max(DateTime.diff(finished, started, :second), 0)

  defp ran(seconds), do: %{status: :ran, duration_seconds: seconds}
  defp not_run, do: %{status: :not_run, duration_seconds: nil}

  defp sum_stages(stages, names) do
    Enum.reduce(names, 0, fn name, total ->
      case Map.fetch!(stages, name) do
        %{status: :ran, duration_seconds: seconds} -> total + seconds
        %{status: :not_run} -> total
      end
    end)
  end

  defp summarize_outcome(timings, outcome) do
    selected = Enum.filter(timings, &(&1.outcome == outcome))

    stages =
      @stages
      |> Enum.map(fn stage ->
        values =
          for timing <- selected,
              %{status: :ran, duration_seconds: seconds} <- [Map.fetch!(timing.stages, stage)],
              do: seconds

        {stage, statistics(values)}
      end)
      |> Enum.reject(fn {_stage, statistics} -> is_nil(statistics) end)
      |> Map.new()

    waits =
      @analyzers
      |> Enum.map(fn source ->
        values =
          for %{analyzer_waits: waits} <- selected,
              %{status: :ran, duration_seconds: seconds} <- [Map.fetch!(waits, source)],
              do: seconds

        {source, statistics(values)}
      end)
      |> Enum.reject(fn {_source, statistics} -> is_nil(statistics) end)
      |> Map.new()

    %{
      "count" => length(selected),
      "stages" => stages,
      "analyzer_waits" => waits,
      "gate_seconds" => Enum.sum(Enum.map(selected, & &1.gate_seconds))
    }
  end

  defp timed_items(runs, key) do
    for %Run{source: source, id: run_id, stats: stats} <- runs,
        source in ["exunit", "spex"],
        item <- get_in(stats || %{}, ["timings", key]) || [],
        is_integer(item["duration_us"]) and item["duration_us"] >= 0 do
      item
      |> Map.take(["name", "file", "duration_us"])
      |> Map.merge(%{
        "source" => source,
        "run_id" => run_id,
        "duration_seconds" => Float.round(item["duration_us"] / 1_000_000, 2)
      })
    end
  end

  defp slowest(timings, key) do
    items = Enum.flat_map(timings, &Map.get(&1, key, []))

    Map.new(["exunit", "spex"], fn source ->
      ranked =
        items
        |> Enum.filter(&(&1["source"] == source))
        |> Enum.sort_by(& &1["duration_us"], :desc)
        |> Enum.take(10)

      {source, ranked}
    end)
  end

  defp statistics([]), do: nil

  defp statistics(values) do
    ordered = Enum.sort(values)
    count = length(ordered)

    %{
      "count" => count,
      "median_seconds" => median(ordered, count),
      "p90_seconds" => Enum.at(ordered, ceil(count * 0.9) - 1),
      "total_seconds" => Enum.sum(ordered)
    }
  end

  defp median(values, count) when rem(count, 2) == 1, do: Enum.at(values, div(count, 2))

  defp median(values, count) do
    middle = div(count, 2)
    (Enum.at(values, middle - 1) + Enum.at(values, middle)) / 2
  end
end

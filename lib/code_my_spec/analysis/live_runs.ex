defmodule CodeMySpec.Analysis.LiveRuns do
  @moduledoc """
  What a run has reported so far, folded from its events as they arrive
  (story 1141): each test's result, the files it is in now, and whether it
  reported finishing. A credo run reports findings instead, and its totals
  when it finishes (story 1144).

  Held in memory only. The ledger row records how a run ended; this is what
  can be seen of it while it runs and after. A run's events reach the server
  in order through its working copy's one channel process, so folding is a
  plain read-then-write.
  """

  use GenServer

  @table __MODULE__
  # Kept for the most recent runs only; older ones are dropped as new ones start.
  @keep 200

  @type test_result :: %{
          name: String.t(),
          file: String.t() | nil,
          line: integer() | nil,
          state: String.t(),
          message: String.t() | nil,
          failure_line: integer() | nil
        }
  @type finding :: %{
          file: String.t() | nil,
          line: integer() | nil,
          message: String.t() | nil,
          check: String.t() | nil
        }
  @type t :: %{
          running_files: [String.t()],
          tests: [test_result()],
          findings: [finding()],
          totals: map() | nil,
          finished?: boolean(),
          last_event_at: DateTime.t() | nil
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "What `run_id` has reported, or nil when it has reported nothing."
  @spec get(integer()) :: t() | nil
  def get(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, live}] -> live
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Fold one event into `run_id`'s state, and answer the new state."
  @spec fold(integer(), map()) :: t()
  def fold(run_id, event) do
    live =
      event
      |> apply_event(get(run_id) || new(run_id))
      |> Map.put(:last_event_at, DateTime.utc_now())

    :ets.insert(@table, {run_id, live})
    live
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, :ok}
  end

  defp new(run_id) do
    prune(run_id)

    %{
      running_files: [],
      tests: [],
      findings: [],
      totals: nil,
      finished?: false,
      last_event_at: nil
    }
  end

  defp prune(run_id) do
    stale = run_id - @keep
    :ets.select_delete(@table, [{{:"$1", :_}, [{:<, :"$1", stale}], [true]}])
  end

  # Test files run concurrently, so the run is in every file started and not
  # yet finished.
  defp apply_event(%{"event" => "file_started", "file" => file}, live),
    do: %{live | running_files: live.running_files ++ [file]}

  defp apply_event(%{"event" => "file_finished", "file" => file}, live),
    do: %{live | running_files: List.delete(live.running_files, file)}

  defp apply_event(%{"event" => "test"} = test, live) do
    result = %{
      name: test["name"],
      file: test["file"],
      line: test["line"],
      state: test["state"],
      message: test["message"],
      failure_line: test["failure_line"]
    }

    %{live | tests: live.tests ++ [result]}
  end

  defp apply_event(%{"event" => "finding"} = finding, live) do
    result = %{
      file: finding["file"],
      line: finding["line"],
      message: finding["message"],
      check: finding["check"]
    }

    %{live | findings: live.findings ++ [result]}
  end

  defp apply_event(%{"event" => "finished"} = event, live),
    do: %{live | finished?: true, totals: Map.take(event, ["files", "findings"])}

  defp apply_event(_event, live), do: live
end

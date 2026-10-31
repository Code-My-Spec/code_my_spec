defmodule CodeMySpec.Analysis.LocalRunLink do
  @moduledoc """
  Where a run this server executes itself reports its events (story 1141):
  the server's counterpart to the harness's `CmsHarness.RunLink`, for a copy's
  own app, which has no harness. Each event is folded in directly with
  `Analysis.record_live_event/3`.
  """

  use GenServer

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.Users.Scope

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  What a run started here for `run_id` needs in its environment to report.
  Nothing where this listener is not running, or for a run with no id.
  """
  @spec env(Scope.t(), integer() | nil) :: [{String.t(), String.t() | nil}]
  def env(_scope, nil), do: []

  def env(%Scope{} = scope, run_id) when is_integer(run_id) do
    if Process.whereis(__MODULE__) do
      :ok = GenServer.call(__MODULE__, {:expect, run_id, scope})
      RunNode.env(run_id, __MODULE__)
    else
      []
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:expect, run_id, scope}, _from, runs) do
    :ok = RunNode.ensure_started("cms_app")
    {:reply, :ok, Map.put(runs, run_id, scope)}
  end

  @impl true
  def handle_info({:run_event, run_id, event}, runs) do
    case Map.fetch(runs, run_id) do
      {:ok, scope} ->
        _ = Analysis.record_live_event(scope, run_id, event)
        {:noreply, forget_finished(runs, run_id, event)}

      :error ->
        {:noreply, runs}
    end
  end

  def handle_info(_message, runs), do: {:noreply, runs}

  defp forget_finished(runs, run_id, %{"event" => "finished"}), do: Map.delete(runs, run_id)
  defp forget_finished(runs, _run_id, _event), do: runs
end

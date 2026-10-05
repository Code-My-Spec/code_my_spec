defmodule CmsHarness.Agents.Engine.Keeper do
  @moduledoc """
  One agent's supervisor: it restarts the agent's process when it crashes, and
  gives up on a crash loop.

  Two children, `:rest_for_one`:

    1. **The transcript** — what the agent knew at its last turn start or
       settle, and the turn in flight if any. Written by the engine as it goes.
    2. **The engine** — `Engine.Server`, `:transient`: restarted on an abnormal
       exit, not on the `:shutdown` a stop or turn-off sends. A restarted engine
       starts from the transcript, so it is the same agent with the same history,
       not a fresh one started from whatever the server sent at its first start.

  The engine crashing restarts only the engine, so the transcript survives it.
  The engine is significant: an exit it is not restarted for (`:normal`) ends
  the Keeper too, rather than leaving an empty supervisor behind.

  **The bound**: 3 restarts in 600 seconds, per agent — the fourth crash in
  ten minutes ends the Keeper, and `Agents.Liveness` reports the agent gone for
  good (`:gave_up`). Per agent so one crash-looping agent takes nothing down
  with it but itself. Conservative on purpose: every lap of a crash loop is a
  provider call, and three is enough to ride out a transient fault.
  """

  use Supervisor, restart: :temporary

  alias CmsHarness.Agents.Engine.Server

  @max_restarts 3
  @max_seconds 600

  @type transcript :: %{messages: [Alloy.Message.t()], in_flight: String.t() | nil}

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    Supervisor.start_link(__MODULE__, opts, name: via(agent_id))
  end

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    children = [
      %{
        id: :transcript,
        start: {Agent, :start_link, [fn -> nil end, [name: transcript(agent_id)]]}
      },
      %{
        id: :engine,
        start: {Server, :start_link, [opts]},
        restart: :transient,
        significant: true
      }
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds,
      auto_shutdown: :any_significant
    )
  end

  @doc "The agent's Keeper, if it has one."
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_running}
  def whereis(agent_id) do
    case Registry.lookup(CmsHarness.Registry, {:keeper, agent_id}) do
      [{pid, _}] -> if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running})
      _ -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  @doc """
  Write down what the agent knows now, and the turn it is in, if any.

  An engine started outside a Keeper (a test driving `Server` directly) has
  nowhere to write, and nothing to restart it either.
  """
  @spec remember(String.t(), transcript()) :: :ok
  def remember(agent_id, transcript, consumed_ref \\ nil) do
    if is_binary(consumed_ref), do: take_queued(agent_id, consumed_ref)

    case Registry.lookup(CmsHarness.Registry, {:transcript, agent_id}) do
      [{pid, _}] ->
        Agent.update(pid, fn _previous -> transcript end)

      [] ->
        :ok
    end
  end

  @doc "Remember an accepted queue ref across harness restarts."
  defdelegate queued(agent_id, ref), to: CmsHarness.Agents.Engine.QueueReceipts

  @doc "Remove an unconsumed receipt when consumed or withdrawn."
  defdelegate take_queued(agent_id, ref), to: CmsHarness.Agents.Engine.QueueReceipts, as: :take

  @doc "What the agent knew when it last wrote it down; `nil` on a first start."
  @spec recall(String.t()) :: transcript() | nil
  def recall(agent_id) do
    case Registry.lookup(CmsHarness.Registry, {:transcript, agent_id}) do
      [{pid, _}] -> Agent.get(pid, & &1)
      [] -> nil
    end
  end

  defp via(agent_id), do: {:via, Registry, {CmsHarness.Registry, {:keeper, agent_id}}}
  defp transcript(agent_id), do: {:via, Registry, {CmsHarness.Registry, {:transcript, agent_id}}}
end

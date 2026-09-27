defmodule CodeMySpec.Conversations.Drafts do
  @moduledoc """
  What an agent is writing right now, before it becomes a message.

  Never stored in the database: the message it turns into is the record, and a
  draft is only a preview of it. Kept here rather than only broadcast so a view
  that mounts mid-turn — a reload, a reconnect, an operator arriving late — shows
  the draft at once instead of waiting for the model's next words, which during
  a tool call may be a long time coming.

  Each broadcast carries the whole draft so far, so a subscriber that missed one
  is corrected by the next. The owning process only holds the table and sweeps
  drafts whose turn never settled (the harness died mid-sentence); reads and
  writes go straight to ETS.

  Per node. A view mounted on another node shows nothing until the next
  broadcast, which PubSub carries everywhere.
  """

  use GenServer

  @table __MODULE__
  @sweep_every :timer.minutes(1)
  @stale_after_ms :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Topic a view subscribes to for one conversation's drafts."
  def topic(conversation_id), do: "conversation:#{conversation_id}:drafts"

  def subscribe(conversation_id),
    do: Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(conversation_id))

  def unsubscribe(conversation_id),
    do: Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, topic(conversation_id))

  @doc "The draft so far, or nil."
  @spec get(Ecto.UUID.t()) :: String.t() | nil
  def get(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, text, _at}] -> text
      [] -> nil
    end
  end

  @spec put(Ecto.UUID.t(), String.t()) :: :ok
  def put(conversation_id, text) when is_binary(text) do
    :ets.insert(@table, {conversation_id, text, System.monotonic_time(:millisecond)})
    broadcast(conversation_id, text)
  end

  @doc "The draft became a message, or never will. Broadcasts nil only if there was one."
  @spec clear(Ecto.UUID.t()) :: :ok
  def clear(conversation_id) do
    case :ets.take(@table, conversation_id) do
      [] -> :ok
      _ -> broadcast(conversation_id, nil)
    end
  end

  defp broadcast(conversation_id, text) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      topic(conversation_id),
      {:agent_draft, conversation_id, text}
    )
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_after_ms

    @table
    |> :ets.select([{{:"$1", :_, :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}])
    |> Enum.each(&clear/1)

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)
end

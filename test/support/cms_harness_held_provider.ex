defmodule CmsHarnessTest.HeldProvider do
  @moduledoc """
  A provider that can be made to think for as long as a criterion needs.

  Story 1024 has three criteria whose premise is "an agent in the middle of a
  turn": a message sent mid-turn is queued, a queued message can be taken back,
  and taking back one the agent already has is refused. None of them can be
  established without an agent that is genuinely busy — and "busy" is not a flag
  the engine can be handed, it is a turn in flight waiting on a provider.

  So this is a real OpenAI-compatible endpoint on localhost, reached through
  the same `Alloy.Provider.OpenAICompat` a z.ai agent uses, over
  `base_url`. Holding a turn means holding the HTTP response, which is what a
  slow model does. Nothing is stubbed and no module is swapped: the agent is
  mid-turn in exactly the way it is mid-turn in production.

  ## What it also gives every other criterion

  `seen/0` is the request bodies the endpoint received, which is the honest
  answer to "did the agent get my message". Asserting on a conversation row
  only proves the server wrote one down; this proves the text reached the loop
  that acts on it.

  ## Modes

  Flowing by default — a request is answered as it arrives, so an ordinary turn
  runs and finishes. `hold/0` makes the next requests wait; `refuse/0` makes
  them fail; `release/0` answers everything waiting and every request after it.
  Release is deliberately sticky:
  a turn that ends drains the agent's queue and starts the next one, and a
  release that only covered requests already in flight would leave that one
  held forever with `await_idle/1` waiting on it.
  """

  @behaviour Plug

  alias CmsHarnessTest.HeldProvider.Store

  # What the agent says back, and it is deliberately not a word like "ok".
  #
  # A page is full of short common words — markup, class names, the CSP nonce —
  # so `html =~ "ok"` passes over a transcript that recorded nothing. An
  # assertion that cannot fail is worse than no assertion, and one of these
  # criteria was passing that way before this string was distinctive.
  @answer "PROVIDER-ANSWERED"

  # One text delta, then a stop. Enough for a turn to complete: Alloy loops
  # until the provider says `finish_reason`, so a response without one is an
  # agent that calls the endpoint forever.
  @sse [
    ~s(data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"#{@answer}"}}]}\n\n),
    ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
    "data: [DONE]\n\n"
  ]

  @doc "What this provider answers with — the needle a criterion looks for."
  @spec answer() :: String.t()
  def answer, do: @answer

  @doc """
  Start the endpoint and answer with the base URL to point an agent at.

  Stopped when the criterion ends, with anything still held released first —
  a plug process parked in a `receive` would otherwise outlive the run.
  """
  @spec start() :: String.t()
  def start do
    Store.reset()

    {:ok, server} =
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    ExUnit.Callbacks.on_exit(fn ->
      Store.release()
      Store.reset()
    end)

    "http://127.0.0.1:#{port}"
  end

  @doc "Make the next turn wait, so an agent can be caught in the middle of one."
  @spec hold() :: :ok
  defdelegate hold(), to: Store

  @doc """
  Make the next turn fail, the way a provider that will not answer fails.

  A 500 with a body, which is what `OpenAICompat` turns into `{:error, …}` —
  the same shape a refused credential or an exhausted plan produces. Nothing
  here simulates the failure at the engine's edge; the engine sees exactly what
  it sees in production.
  """
  @spec refuse() :: :ok
  defdelegate refuse(), to: Store

  @doc "Let every waiting turn finish, and every one after it."
  @spec release() :: :ok
  defdelegate release(), to: Store

  @doc """
  Wait until a turn is actually in flight.

  Without this, "the agent is mid-turn" is a race: the message has been
  accepted and the request may not have left yet, so the next step could send
  its message to an idle agent and find it started rather than queued.
  """
  @spec await_request(timeout()) :: :ok
  defdelegate await_request(timeout \\ 5_000), to: Store

  @doc "Every request body this endpoint has been sent, newest last."
  @spec seen() :: [String.t()]
  defdelegate seen(), to: Store

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Blocks here while held, which is the whole point: the agent's turn is
    # waiting on this response the way it waits on a slow model.
    case Store.arrived(body) do
      :ok -> answer(conn)
      :refuse -> refusal(conn)
    end
  end

  defp answer(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> stream_response()
  end

  # What a provider that will not answer looks like from the harness's side.
  #
  # 401, not 500. `Alloy.Provider.Retry` treats 5xx as transient and retries it
  # with backoff, so a criterion refusing with one is waiting out a retry
  # schedule rather than watching a turn fail. A refused credential is both
  # terminal and the failure operators actually meet.
  defp refusal(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      401,
      ~s({"error":{"message":"the model backend refused this request","type":"invalid_request_error"}})
    )
  end

  defp stream_response(conn) do
    Enum.reduce(@sse, conn, fn data, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, data)
      conn
    end)
  end

  defmodule Store do
    @moduledoc """
    What the endpoint has been asked, and who is waiting on it.

    A process rather than an ETS table because holding a request *is* an
    unanswered `GenServer.call`: the plug parks in the call, and releasing is
    replying to it. That keeps the block and the bookkeeping in one place
    instead of a table plus a set of monitored pids.

    Started unlinked and named, like the harness's registry and agent
    supervisor, because criteria start and stop endpoints while it has to keep
    answering. `reset/0` is what makes one run independent of the next.
    """

    use GenServer

    @spec reset() :: :ok
    def reset do
      ensure_started()
      GenServer.call(__MODULE__, :reset)
    end

    @spec hold() :: :ok
    def hold do
      ensure_started()
      GenServer.call(__MODULE__, :hold)
    end

    @spec refuse() :: :ok
    def refuse do
      ensure_started()
      GenServer.call(__MODULE__, :refuse)
    end

    @spec release() :: :ok
    def release do
      ensure_started()
      GenServer.call(__MODULE__, :release)
    end

    @spec seen() :: [String.t()]
    def seen do
      ensure_started()
      GenServer.call(__MODULE__, :seen)
    end

    @spec arrived(String.t()) :: :ok | :refuse
    def arrived(body) do
      ensure_started()
      GenServer.call(__MODULE__, {:arrived, body}, :infinity)
    end

    @spec await_request(timeout()) :: :ok
    def await_request(timeout) do
      ensure_started()
      GenServer.call(__MODULE__, :await_request, timeout)
    end

    defp ensure_started do
      case Process.whereis(__MODULE__) do
        nil ->
          # Unlinked: it outlives the criterion that first needed it, the same
          # way the harness registry does, so the next one does not race a
          # dying process.
          {:ok, _pid} = GenServer.start(__MODULE__, :ok, name: __MODULE__)
          :ok

        _pid ->
          :ok
      end
    end

    @impl true
    def init(:ok), do: {:ok, %{mode: :flowing, held: [], seen: [], waiting: []}}

    @impl true
    def handle_call(:reset, _from, state) do
      Enum.each(state.held, &GenServer.reply(&1, :ok))
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      {:reply, :ok, %{mode: :flowing, held: [], seen: [], waiting: []}}
    end

    def handle_call(:hold, _from, state), do: {:reply, :ok, %{state | mode: :holding}}

    def handle_call(:refuse, _from, state), do: {:reply, :ok, %{state | mode: :refusing}}

    def handle_call(:release, _from, state) do
      Enum.each(state.held, &GenServer.reply(&1, :ok))
      {:reply, :ok, %{state | mode: :flowing, held: []}}
    end

    def handle_call(:seen, _from, state), do: {:reply, Enum.reverse(state.seen), state}

    def handle_call({:arrived, body}, from, state) do
      # Recorded before anything is decided about answering it, so a criterion
      # asking what the agent was sent gets the same answer whether the turn
      # is still running or already finished.
      state = %{state | seen: [body | state.seen]}

      case state.mode do
        :flowing -> {:reply, :ok, state}
        :refusing -> {:reply, :refuse, state}
        :holding -> {:noreply, hold_request(state, from)}
      end
    end

    # Already in flight, so there is nothing to wait for.
    def handle_call(:await_request, _from, %{held: [_ | _]} = state), do: {:reply, :ok, state}

    def handle_call(:await_request, from, state),
      do: {:noreply, %{state | waiting: [from | state.waiting]}}

    defp hold_request(state, from) do
      Enum.each(state.waiting, &GenServer.reply(&1, :ok))
      %{state | held: [from | state.held], waiting: []}
    end
  end
end

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
  `hold_mid_reply/0` answers the next request with `reply_so_far/0` and waits
  there, part-way through, until `release/0` finishes it as `whole_reply/0` or
  `drop/0` drops the connection and refuses what comes after.
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

  # Distinctive for the same reason `@answer` is, and in two halves so a reply
  # can be caught between them: the first half on the page and the whole not
  # yet, which is what "part-way through a reply" means.
  @so_far "PROVIDER-STARTED-"
  @rest "AND-FINISHED"

  @doc "What a reply held by `hold_mid_reply/0` has said when it stops."
  @spec reply_so_far() :: String.t()
  def reply_so_far, do: @so_far

  @doc "What that reply says once `release/0` lets it finish."
  @spec whole_reply() :: String.t()
  def whole_reply, do: @so_far <> @rest

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
    {:ok, store} = GenServer.start(Store, :ok)
    Process.put(Store, store)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    # Unlinked so it outlives the test process until on_exit stops it in
    # order; linked, it died with the test and raced the stop below.
    true = Process.unlink(server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(store), do: GenServer.call(store, :release)
      if Process.alive?(server), do: GenServer.stop(server)
      if Process.alive?(store), do: GenServer.stop(store)
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

  @doc "Answer the next request part-way, and wait there."
  @spec hold_mid_reply() :: :ok
  defdelegate hold_mid_reply(), to: Store

  @doc """
  Drop the connection of a reply held part-way, and refuse what follows.

  A dropped connection is transient to `Alloy.Provider.Retry`, so the turn
  asks again — and is refused, which is terminal. The turn fails the way it
  fails when a provider goes away mid-sentence and will not take it back.
  """
  @spec drop() :: :ok
  defdelegate drop(), to: Store

  @doc "Let every waiting turn finish, and every one after it."
  @spec release() :: :ok
  defdelegate release(), to: Store

  @doc """
  Answer the waiting request by calling `tool` with `arguments`, and flow after.

  A turn with a tool boundary in it: the agent runs the call and asks again,
  and that next request is what a message sent now arrives in (story 1051).
  """
  @spec release_with_tool_call(String.t(), map(), keyword()) :: :ok
  defdelegate release_with_tool_call(tool, arguments, opts \\ []), to: Store

  @doc """
  Wait until a turn is actually in flight.

  Without this, "the agent is mid-turn" is a race: the message has been
  accepted and the request may not have left yet, so the next step could send
  its message to an idle agent and find it started rather than queued.
  """
  @spec await_request(timeout()) :: :ok
  defdelegate await_request(timeout \\ CmsHarnessTest.GateWait.event_timeout()), to: Store

  @doc "Every request body this endpoint has been sent, newest last."
  @spec seen() :: [String.t()]
  defdelegate seen(), to: Store

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, store) do
    Process.put(Store, store)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Blocks here while held, which is the whole point: the agent's turn is
    # waiting on this response the way it waits on a slow model.
    case Store.arrived(body) do
      :ok -> answer(conn)
      :refuse -> refusal(conn)
      :midway -> answer_midway(conn)
      {:tool_call, tool, arguments} -> answer_tool_call(conn, tool, arguments)
    end
  end

  defp answer_tool_call(conn, tool, arguments) do
    call = %{
      "index" => 0,
      "id" => "call_held_1",
      "type" => "function",
      "function" => %{"name" => tool, "arguments" => Jason.encode!(arguments)}
    }

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> send_chunks([
      "data: " <>
        Jason.encode!(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"role" => "assistant", "tool_calls" => [call]}}
          ]
        }) <> "\n\n",
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n),
      "data: [DONE]\n\n"
    ])
  end

  defp answer_midway(conn) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)
      |> send_chunks([delta(@so_far)])

    case Store.park() do
      :ok ->
        send_chunks(conn, [delta(@rest) | tl(@sse)])

      # Killed rather than returned from: returning finishes the chunked
      # response cleanly, which reads as a reply that simply stopped. Killing the
      # connection's process closes the socket mid-stream, which is a dropped
      # connection.
      :drop ->
        Process.exit(self(), :kill)
    end
  end

  defp delta(text),
    do: ~s(data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"#{text}"}}]}\n\n)

  defp answer(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> send_chunks(@sse)
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

  # A client that hung up stops the stream. Sending now interrupts the turn
  # whose request this is, so the harness closing it mid-stream is expected.
  defp send_chunks(conn, chunks) do
    Enum.reduce_while(chunks, conn, fn data, conn ->
      case Plug.Conn.chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defmodule Store do
    @moduledoc """
    What the endpoint has been asked, and who is waiting on it.

    A process rather than an ETS table because holding a request *is* an
    unanswered `GenServer.call`: the plug parks in the call, and releasing is
    replying to it. That keeps the block and the bookkeeping in one place
    instead of a table plus a set of monitored pids.

    Each endpoint owns an unnamed store. The scenario and its child tasks
    address that store through the caller's process dictionary; HTTP handlers
    receive it in their plug options. Teardown releases and stops only that
    endpoint's resources, so another scenario cannot reset its requests.

    """

    use GenServer

    @spec reset() :: :ok
    def reset do
      GenServer.call(store!(), :reset)
    end

    @spec hold() :: :ok
    def hold do
      GenServer.call(store!(), :hold)
    end

    @spec hold_mid_reply() :: :ok
    def hold_mid_reply do
      GenServer.call(store!(), :hold_mid_reply)
    end

    @spec drop() :: :ok
    def drop do
      GenServer.call(store!(), :drop)
    end

    @spec park() :: :ok | :drop
    def park do
      GenServer.call(store!(), :park, :infinity)
    end

    @spec refuse() :: :ok
    def refuse do
      GenServer.call(store!(), :refuse)
    end

    @spec release() :: :ok
    def release do
      GenServer.call(store!(), :release)
    end

    @doc """
    Answer the held request with a tool call. `then: :hold` keeps holding what
    comes next — the turn's request after the tool runs — so the turn is still
    running when a test acts on it; the default lets it flow.
    """
    @spec release_with_tool_call(String.t(), map(), keyword()) :: :ok
    def release_with_tool_call(tool, arguments, opts \\ []) do
      GenServer.call(store!(), {:release_with_tool_call, tool, arguments, opts})
    end

    @spec seen() :: [String.t()]
    def seen do
      GenServer.call(store!(), :seen)
    end

    @spec arrived(String.t()) :: :ok | :refuse | :midway | {:tool_call, String.t(), map()}
    def arrived(body) do
      GenServer.call(store!(), {:arrived, body}, :infinity)
    end

    @spec await_request(timeout()) :: :ok
    def await_request(timeout) do
      GenServer.call(store!(), :await_request, timeout)
    end

    defp store! do
      owners = [self() | Process.get(:"$callers", [])]

      Enum.find_value(owners, fn owner ->
        case Process.info(owner, :dictionary) do
          {:dictionary, dictionary} -> Keyword.get(dictionary, __MODULE__)
          nil -> nil
        end
      end) || raise "HeldProvider.start/0 must be called before using its store"
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

    def handle_call(:hold_mid_reply, _from, state),
      do: {:reply, :ok, %{state | mode: :holding_mid_reply}}

    def handle_call(:drop, _from, state) do
      Enum.each(state.held, &GenServer.reply(&1, :drop))
      {:reply, :ok, %{state | mode: :refusing, held: []}}
    end

    # The half reply has been sent; the request waits here for the rest.
    def handle_call(:park, from, state), do: {:noreply, hold_request(state, from)}

    def handle_call(:release, _from, state) do
      Enum.each(state.held, &GenServer.reply(&1, :ok))
      {:reply, :ok, %{state | mode: :flowing, held: []}}
    end

    def handle_call({:release_with_tool_call, tool, arguments, opts}, _from, state) do
      Enum.each(state.held, &GenServer.reply(&1, {:tool_call, tool, arguments}))
      mode = if opts[:then] == :hold, do: :holding, else: :flowing
      {:reply, :ok, %{state | mode: mode, held: []}}
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
        # Only the one reply is caught part-way; the turn after it flows.
        :holding_mid_reply -> {:reply, :midway, %{state | mode: :flowing}}
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

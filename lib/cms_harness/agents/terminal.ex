defmodule CmsHarness.Agents.Terminal do
  @moduledoc """
  A Claude Code session in a person's terminal, as an agent on this harness
  (stories 1123, 1124).

  It answers the agent contract in `CmsHarness.Agents` by writing to the
  session's own inbox socket: Claude Code reads a message between tool calls,
  or starts a turn with it when idle. The session queues what it is sent, so
  this is never busy, a written message is delivered (a `delivered` event
  settles its mailbox entry), and nothing it is sent can be interrupted.

  Its state is read from Claude Code's own agent list (`claude agents --json`,
  story 1124): its session going busy is a turn starting, going idle the turn
  ending, and leaving the list the agent ending — watched by `Liveness`, so
  the server sees it come and go through Presence like any other, and an
  exited session reads as gone rather than stalled. Where the list cannot be
  read, the socket answering stands in for it. The socket and its key stay on
  this machine; the server never sees either.

  Frames are newline-delimited JSON: an optional auth line carrying the
  session's peer token, then a user message (knowledge/harness, "Terminal
  agents").
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Agents.Transcript
  alias CmsHarness.Channel
  alias CmsHarness.Copy.Supervisor, as: Copy

  @check_ms 15_000
  @connect_timeout_ms 2_000

  @doc """
  Serve `agent_id` through the session `session` describes: its `:socket`,
  the `:working_copy` it runs in, and its `:session_id` and `:transcript` path
  when known. Already serving it: the session is updated, since a resumed
  session binds a new socket.
  """
  @spec attach(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def attach(agent_id, %{socket: socket, working_copy: working_copy} = session) do
    case CmsHarness.Agents.whereis(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:session, session})
        {:ok, pid}

      {:error, :not_running} ->
        with {:ok, _copy} <- Copy.ensure(working_copy) do
          DynamicSupervisor.start_child(
            Copy.agents(working_copy),
            {__MODULE__,
             agent_id: agent_id,
             socket: socket,
             working_copy: working_copy,
             session_id: session[:session_id],
             transcript: session[:transcript]}
          )
        end
    end
  end

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {CmsHarness.Registry, {:agent, agent_id}}}
    )
  end

  @impl true
  def init(opts) do
    state = %{
      agent_id: Keyword.fetch!(opts, :agent_id),
      socket: Keyword.fetch!(opts, :socket),
      working_copy: Path.expand(Keyword.fetch!(opts, :working_copy)),
      session_id: Keyword.get(opts, :session_id),
      busy?: false,
      # Read from where it ends now: what came before is the session's own.
      transcript: Keyword.get(opts, :transcript),
      offset: Transcript.end_of(Keyword.get(opts, :transcript)),
      seen: MapSet.new(),
      tools: %{},
      spent: [],
      generation: Ecto.UUID.generate(),
      # In-process callers (tests) may answer the mailbox themselves.
      mailbox: Keyword.get(opts, :mailbox, &Channel.mailbox/2),
      report: Keyword.get(opts, :report, &Channel.report_turn_event/3),
      sessions: Keyword.get(opts, :sessions)
    }

    case register(state) do
      :ok ->
        Liveness.watch(state.agent_id, self(), state.working_copy)
        send(self(), :mailbox_ready)
        schedule_check()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, ref, text, _timeout, _await?}, _from, state) do
    with :ok <- consume(state, ref),
         :ok <- deliver(state.socket, text) do
      report(state, %{event: :delivered, ref: ref, generation: state.generation})
      {:reply, {:ok, :started}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:work_available, _ref, text, _timeout}, _from, state) do
    case deliver(state.socket, text) do
      :ok -> {:reply, {:ok, :started}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, {:ok, %{busy?: false}}, state}
  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :unsupported}, state}

  def handle_call({:session, session}, _from, state) do
    transcript = session[:transcript] || state.transcript

    {:reply, :ok,
     %{
       state
       | socket: session.socket,
         session_id: session[:session_id] || state.session_id,
         transcript: transcript,
         offset:
           if(transcript == state.transcript,
             do: state.offset,
             else: Transcript.end_of(transcript)
           )
     }}
  end

  @impl true
  def handle_info(:mailbox_ready, state) do
    report(state, %{event: :mailbox_ready, generation: state.generation, ref: nil})
    {:noreply, state}
  end

  def handle_info(:check, state) do
    state = read_transcript(state)

    case observe(state) do
      :gone ->
        Logger.info("[CmsHarness] terminal agent #{state.agent_id} gone: its session ended")
        {:stop, :normal, settle_turn(state, false)}

      busy? ->
        schedule_check()
        {:noreply, settle_turn(state, busy?)}
    end
  end

  # Busy, idle (`false`), or `:gone` — from Claude Code's agent list when it can
  # be read, else from whether the socket answers (idle while it does).
  defp observe(%{session_id: session_id} = state) when is_binary(session_id) do
    case lookup(state, session_id) do
      {:ok, status} -> status == "busy"
      :gone -> :gone
      :error -> socket_answers(state)
    end
  end

  defp observe(state), do: socket_answers(state)

  # A test hands the list in (`:sessions`); the application may name another
  # source, asked by session id; otherwise `claude` itself.
  defp lookup(%{sessions: sessions}, session_id) when is_function(sessions, 0),
    do: sessions |> apply([]) |> find(session_id)

  defp lookup(_state, session_id) do
    case Application.get_env(:code_my_spec, :claude_sessions) do
      {module, function, args} -> apply(module, function, args ++ [session_id])
      nil -> find(claude_sessions(), session_id)
    end
  end

  defp find({:ok, sessions}, session_id) do
    case Enum.find(sessions, &(&1["sessionId"] == session_id)) do
      nil -> :gone
      session -> {:ok, session["status"]}
    end
  end

  defp find(:error, _session_id), do: :error

  defp socket_answers(state) do
    case connect(state.socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        state.busy?

      {:error, _} ->
        :gone
    end
  end

  # A turn starting is the agent's own; one ending is `turn_over`, which the
  # server settles as it settles an engine's turn end.
  defp settle_turn(%{busy?: busy?} = state, busy?), do: state

  defp settle_turn(state, true) do
    report(state, %{event: :turn_started, generation: state.generation, ref: nil})
    %{state | busy?: true}
  end

  defp settle_turn(state, false) do
    report_spent(state)
    report(state, %{event: :turn_over, generation: state.generation, ref: nil})
    %{state | busy?: false, spent: []}
  end

  # What the session said and did since the last look, as the steps an agent
  # we run reports, and what its responses cost, held for the turn's end.
  defp read_transcript(%{transcript: path} = state) when is_binary(path) do
    read = Transcript.read(path, state.offset, state.seen, state.tools)
    Enum.each(read.events, &report(state, &1))

    %{
      state
      | offset: read.offset,
        seen: read.seen,
        tools: read.tools,
        spent: state.spent ++ read.usage
    }
  end

  defp read_transcript(state), do: state

  defp report_spent(%{spent: []}), do: :ok

  defp report_spent(%{spent: spent} = state) do
    report(state, %{
      event: :turn_usage,
      usage: total(spent),
      generation: state.generation,
      ref: nil
    })
  end

  @counted ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  defp total(spent) do
    @counted
    |> Map.new(fn key -> {key, spent |> Enum.map(&(&1[key] || 0)) |> Enum.sum()} end)
    |> Map.put("model", spent |> List.last() |> Map.get("model"))
  end

  @doc "The interactive Claude Code sessions on this machine, as `claude agents --json` lists them."
  @spec claude_sessions() :: {:ok, [map()]} | :error
  def claude_sessions do
    with {out, 0} <- System.cmd("claude", ["agents", "--json"], stderr_to_stdout: false),
         {:ok, sessions} when is_list(sessions) <- Jason.decode(out) do
      {:ok, sessions}
    else
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_ms)

  defp report(state, envelope),
    do: state.report.(state.working_copy, state.agent_id, envelope)

  defp register(state) do
    case state.mailbox.(state.working_copy, %{
           "operation" => "register",
           "agent_id" => state.agent_id,
           "generation" => state.generation
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp consume(state, ref) do
    case state.mailbox.(state.working_copy, %{
           "operation" => "consume",
           "agent_id" => state.agent_id,
           "ref" => ref,
           "generation" => state.generation
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Write `text` to the session at `socket` as one user message."
  @spec deliver(String.t(), String.t()) :: :ok | {:error, term()}
  def deliver(socket, text) do
    frames = auth_frame(socket) ++ [frame(text)]

    with {:ok, conn} <- connect(socket) do
      result = :gen_tcp.send(conn, frames)
      :gen_tcp.close(conn)
      result
    end
  end

  defp frame(text),
    do: Jason.encode!(%{type: "user", message: %{role: "user", content: text}}) <> "\n"

  # Optional on macOS and Linux, where the socket is already the user's alone;
  # sent whenever the session published a key, as peers of the same user do.
  defp auth_frame(socket) do
    case peer_token(socket) do
      nil -> []
      token -> [Jason.encode!(%{type: "auth", token: token}) <> "\n"]
    end
  end

  @doc """
  The peer token the session at `socket` published, or nil: a session writes
  `<pid>.<sha256 of its socket path>.key` into its config directory's
  `sessions/`, readable by this user only.
  """
  @spec peer_token(String.t(), String.t()) :: String.t() | nil
  def peer_token(socket, dir \\ sessions_dir()) do
    hash = :sha256 |> :crypto.hash(socket) |> Base.encode16(case: :lower)

    with [path | _] <- Path.wildcard(Path.join(dir, "*.#{hash}.key")),
         {:ok, body} <- File.read(path),
         {:ok, %{"peerToken" => token}} when is_binary(token) <- Jason.decode(body) do
      token
    else
      _ -> nil
    end
  end

  defp sessions_dir do
    config = System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude")
    Path.join(config, "sessions")
  end

  defp connect(socket) do
    :gen_tcp.connect(
      {:local, String.to_charlist(socket)},
      0,
      [:binary, active: false],
      @connect_timeout_ms
    )
  end
end

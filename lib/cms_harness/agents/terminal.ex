defmodule CmsHarness.Agents.Terminal do
  @moduledoc """
  A Claude Code session in a person's terminal, as an agent on this harness
  (stories 1123, 1124).

  It answers the agent contract in `CmsHarness.Agents` by writing to the
  session's own inbox socket: Claude Code reads a message between tool calls,
  or starts a turn with it when idle. The session queues what it is sent, so
  this is never busy, a written message is delivered (a `delivered` event
  settles its mailbox entry), and nothing it is sent can be interrupted.

  Its turns come from the session's own hooks (story 1127), which the harness
  hands it as they fire: a prompt submitted starts a turn, a stop that lets the
  session end it ends one, a tool call is the tool it is running, a permission
  prompt is the session waiting on its person, and the session ending closes
  whatever was open. A session running with hooks disabled reads idle: Claude
  Code's agent list is read for presence only (story 1124), watched by
  `Liveness`, so the server sees it come and go through Presence like any
  other, and an exited session reads as gone rather than stalled. Where the
  list cannot be read, the socket answering stands in for it. The socket and
  its key stay on this machine; the server never sees either.

  Frames are newline-delimited JSON: an optional auth line carrying the
  session's peer token, then a user message (knowledge/harness, "Terminal
  agents").

  A Codex session (story 1128) has no inbox socket. It is told things the way
  Codex takes them: `codex queue --thread <session> --message <text>` puts the
  message in the session, which Codex reads when it chooses, so this too is
  never busy and nothing it is sent can be interrupted. Its turns come from its
  hooks as a Claude Code session's do. Codex has no agent list, so the session
  is present until its session-end hook, or this harness stops.
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
  @spec attach(String.t(), map()) :: {:ok, pid()} | {:error, :session_ended | term()}
  def attach(agent_id, %{working_copy: working_copy} = session) do
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
             socket: session[:socket],
             engine: session[:engine] || :claude_code,
             working_copy: working_copy,
             session_id: session[:session_id],
             transcript: session[:transcript]}
          )
          |> started()
        end
    end
  end

  # `init/1` declines a session that already ended, so nothing reports it up.
  defp started(:ignore), do: {:error, :session_ended}
  defp started(other), do: other

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
      socket: Keyword.get(opts, :socket),
      engine: Keyword.get(opts, :engine, :claude_code),
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
      report_up: Keyword.get(opts, :report_up, &Channel.report_agent_up/2),
      sessions: Keyword.get(opts, :sessions)
    }

    # Asked before anything says it is up: a reconnect re-attaches every terminal
    # agent whose session record survives, and one whose session already ended
    # went up and then down at its first check, a presence flap that let a
    # message through to a closed session.
    with :alive <- observe(state),
         :ok <- register(state) do
      register_session(state)
      Liveness.watch(state.agent_id, self(), state.working_copy)
      report_up(state)
      send(self(), :mailbox_ready)
      schedule_check()
      {:ok, state}
    else
      :gone -> :ignore
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, ref, text, _timeout, _await?}, _from, state) do
    with :ok <- consume(state, ref),
         :ok <- deliver_to(state, text) do
      report(state, %{event: :delivered, ref: ref, generation: state.generation})
      {:reply, {:ok, :started}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:work_available, _ref, text, _timeout}, _from, state) do
    case deliver_to(state, text) do
      :ok -> {:reply, {:ok, :started}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, {:ok, %{busy?: false}}, state}
  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :unsupported}, state}

  def handle_call({:session, session}, _from, state) do
    transcript = session[:transcript] || state.transcript

    state = %{
      state
      | socket: session[:socket] || state.socket,
        session_id: session[:session_id] || state.session_id,
        transcript: transcript,
        offset:
          if(transcript == state.transcript,
            do: state.offset,
            else: Transcript.end_of(transcript)
          )
    }

    # Issue c67e1ab7: this process survived the harness restart that just
    # reconnected it (CmsHarness.Agents.whereis/1 found it already running,
    # so `attach/2` never reached `init/1` and never ran the report_up fix
    # from d12aa283/e79e42de0). If `busy?` was already true before the
    # restart and stays true straight through it, `settle_turn/2`'s own
    # no-op clause (`%{busy?: busy?} = state, busy?`) never sees a
    # transition either, so nothing else would ever re-announce this agent
    # up. A fresh session arriving here -- a new socket, every time -- is
    # itself the re-attach; report it unconditionally.
    report_up(state)

    {:reply, :ok, state}
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
        {:stop, :normal, end_turn(state)}

      :alive ->
        schedule_check()
        {:noreply, state}
    end
  end

  # A hook the session fired (story 1127), handed over by the harness's hook
  # endpoint. The turn it opens or closes is the session's own say-so, never
  # Claude Code's agent list.
  def handle_info({:hook, "user-prompt-submit", _params, _decision}, state),
    do: {:noreply, settle_turn(state, true)}

  def handle_info({:hook, "stop", _params, %{"decision" => "block"}}, state),
    do: {:noreply, state}

  def handle_info({:hook, "stop", _params, _decision}, state) do
    state = read_transcript(state)
    {:noreply, state |> end_turn() |> tool_activity(nil)}
  end

  def handle_info({:hook, "session-end", _params, _decision}, state) do
    state = read_transcript(state)
    {:stop, :normal, end_turn(state)}
  end

  def handle_info({:hook, "pre-tool-use", params, _decision}, state),
    do: {:noreply, tool_activity(state, tool_of(params))}

  def handle_info({:hook, "post-tool-use", _params, _decision}, state),
    do: {:noreply, tool_activity(state, nil)}

  # The session is waiting on its person (a permission prompt): its turn is
  # still open, but it cannot take work.
  def handle_info({:hook, "notification", %{"notification_type" => type}, _decision}, state)
      when type in ["permission_prompt", "elicitation_dialog"] do
    report(state, %{event: :waiting, generation: state.generation, ref: nil})
    {:noreply, state}
  end

  def handle_info({:hook, _other, _params, _decision}, state), do: {:noreply, state}

  # `:alive` or `:gone` — from Claude Code's agent list when it can be read,
  # else from whether the socket answers. Never busy or idle: that is the hooks'.
  defp observe(%{engine: :codex}), do: :alive

  defp observe(%{session_id: session_id} = state) when is_binary(session_id) do
    case lookup(state, session_id) do
      {:ok, _status} -> :alive
      :gone -> :gone
      :error -> socket_answers(state)
    end
  end

  defp observe(state), do: socket_answers(state)

  # A test hands the list in (`:sessions`); the application may name another
  # source, asked by session id; otherwise Claude Code's session registry.
  defp lookup(%{sessions: sessions}, session_id) when is_function(sessions, 0),
    do: sessions |> apply([]) |> find(session_id)

  defp lookup(_state, session_id) do
    case Application.get_env(:code_my_spec, :claude_sessions) do
      {module, function, args} -> apply(module, function, args ++ [session_id])
      nil -> from_registry(session_id)
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
        :alive

      {:error, _} ->
        :gone
    end
  end

  # A turn starting is the agent's own; one ending is `turn_over`, which the
  # server settles as it settles an engine's turn end.
  defp settle_turn(%{busy?: busy?} = state, busy?), do: state

  defp settle_turn(state, true) do
    # A second confirmation that this agent is up, at the moment a real turn
    # is observed -- belt and suspenders beside the one `register/1` sends at
    # `init/1` (issue d12aa283): if that first one was ever missed, a turn
    # starting is as good a moment as any to say so again.
    report_up(state)
    report(state, %{event: :turn_started, generation: state.generation, ref: nil})
    %{state | busy?: true}
  end

  # The turn closes whether or not this process saw it open: a harness restart
  # loses `busy?`, and the server's turn is still open.
  defp end_turn(state) do
    report_spent(state)
    report(state, %{event: :turn_over, generation: state.generation, ref: nil})
    %{state | busy?: false, spent: []}
  end

  # The tool the session is running now, or nil: what the team panel shows
  # beside an Alloy agent's own tool calls, without writing the call twice.
  defp tool_activity(state, tool) do
    report(state, %{event: :tool_activity, payload: tool, generation: state.generation, ref: nil})
    state
  end

  defp tool_of(%{"tool_name" => name} = params) when is_binary(name),
    do: %{name: name, input: params["tool_input"] || %{}}

  defp tool_of(_params), do: nil

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

  @doc """
  What Claude Code's own session registry says of `session_id`, or nil: each
  live session writes `<pid>.json` into its config directory's `sessions/` —
  its `cwd`, `version`, `status` (busy or idle) and, from v2.1.224,
  `messagingSocketPath` — and removes it when it exits. The same source
  `claude agents --json` reads, without running `claude`.

  A session resumed under a new pid can leave its old file behind if that
  process never exits cleanly (issue d12aa283), so more than one file can
  name the same session id; the one most recently written to is the live
  session, regardless of directory listing order.
  """
  @spec session_record(String.t(), String.t()) :: map() | nil
  def session_record(session_id, dir \\ sessions_dir()) when is_binary(session_id) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce(nil, &newest_match(&1, session_id, &2))
    |> case do
      nil -> nil
      {_mtime, record} -> record
    end
  end

  defp newest_match(path, session_id, newest) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"sessionId" => ^session_id} = record} <- first_object(body),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path),
         true <- newer?(mtime, newest) do
      {mtime, record}
    else
      _ -> newest
    end
  end

  defp newer?(_mtime, nil), do: true
  defp newer?(mtime, {newest_mtime, _record}), do: mtime >= newest_mtime

  # Claude Code 2.1.293 can leave a stray `}` after a session's object (seen
  # live, 2026-10-18), so the first complete object is the record.
  defp first_object(body) do
    case Jason.decode(body) do
      {:ok, _} = decoded -> decoded
      {:error, _} -> shortest_object(body, :binary.matches(body, "}"))
    end
  end

  defp shortest_object(_body, []), do: :error

  defp shortest_object(body, [{at, 1} | rest]) do
    case Jason.decode(binary_part(body, 0, at + 1)) do
      {:ok, %{}} = decoded -> decoded
      _ -> shortest_object(body, rest)
    end
  end

  defp from_registry(session_id) do
    case session_record(session_id) do
      nil -> :gone
      record -> {:ok, record["status"]}
    end
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_ms)

  # The hook endpoint finds this process by the session id every hook carries.
  defp register_session(%{session_id: session_id}) when is_binary(session_id),
    do: Registry.register(CmsHarness.Registry, {:terminal_session, session_id}, nil)

  defp register_session(_state), do: :ok

  @doc "Hand a hook the session fired to its agent, if this harness serves one for it."
  @spec hook(String.t() | nil, String.t(), map(), map()) :: :ok
  def hook(session_id, name, params, decision) when is_binary(session_id) do
    case Registry.lookup(CmsHarness.Registry, {:terminal_session, session_id}) do
      [{pid, _}] -> send(pid, {:hook, name, params, decision})
      [] -> :ok
    end

    :ok
  end

  def hook(_session_id, _name, _params, _decision), do: :ok

  defp report(state, envelope),
    do: state.report.(state.working_copy, state.agent_id, envelope)

  defp report_up(state), do: state.report_up.(state.working_copy, state.agent_id)

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

  # Codex queues what it is told into the session itself. The command is the
  # machine's `codex`, unless the application names another.
  defp deliver_to(%{engine: :codex, session_id: thread}, text), do: queue_into(thread, text)
  defp deliver_to(%{socket: socket}, text), do: deliver(socket, text)

  @doc """
  Queue `text` into the Codex session `thread` with `codex queue`. Whether this
  Codex has the command is `queue_supported?/0`.
  """
  @spec queue_into(String.t(), String.t()) :: :ok | {:error, term()}
  def queue_into(thread, text) do
    with {:ok, codex} <- codex_executable(),
         {_out, 0} <- run(codex, ["queue", "--thread", thread, "--message", text]) do
      :ok
    else
      {:error, _} = error -> error
      {out, status} -> {:error, {:codex_queue, status, String.trim(out)}}
    end
  end

  @doc "Whether the machine's Codex takes `codex queue` (Codex CLI 0.163 and later)."
  @spec queue_supported?() :: boolean()
  def queue_supported? do
    with {:ok, codex} <- codex_executable(),
         {_out, 0} <- run(codex, ["queue", "--help"]) do
      true
    else
      _ -> false
    end
  end

  defp run(codex, args), do: System.cmd(codex, args, stderr_to_stdout: true)

  defp codex_executable do
    case System.find_executable(codex_command()) do
      nil -> {:error, :codex_not_found}
      path -> {:ok, path}
    end
  end

  defp codex_command, do: Application.get_env(:cms_harness, :codex_command, "codex")

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

  # Claude Code's own config directory, unless the application names another
  # (tests do, so nothing reads this machine's real sessions).
  defp sessions_dir do
    config =
      Application.get_env(:code_my_spec, :claude_config_dir) ||
        System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude")

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

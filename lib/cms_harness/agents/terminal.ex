defmodule CmsHarness.Agents.Terminal do
  @moduledoc """
  A Claude Code session in a person's terminal, as an agent on this harness
  (stories 1123, 1124).

  It answers the agent contract in `CmsHarness.Agents` by writing to the
  session's own inbox socket: Claude Code reads a message between tool calls,
  or starts a turn with it when idle. The session queues what it is sent, so
  this is never busy, a written message is delivered (a `delivered` event
  settles its mailbox entry), and nothing it is sent can be interrupted.

  It lives while the session's socket answers, watched by `Liveness`, so the
  server sees a terminal agent come and go through Presence like any other.
  The socket and its key stay on this machine; the server never sees either.

  Frames are newline-delimited JSON: an optional auth line carrying the
  session's peer token, then a user message (knowledge/harness, "Terminal
  agents").
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Channel
  alias CmsHarness.Copy.Supervisor, as: Copy

  @check_ms 15_000
  @connect_timeout_ms 2_000

  @doc """
  Serve `agent_id` through the session at `socket`, in the working copy at
  `working_copy`. Already serving it: the socket is updated, since a resumed
  session binds a new one.
  """
  @spec attach(String.t(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def attach(agent_id, socket, working_copy) do
    case CmsHarness.Agents.whereis(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:socket, socket})
        {:ok, pid}

      {:error, :not_running} ->
        with {:ok, _copy} <- Copy.ensure(working_copy) do
          DynamicSupervisor.start_child(
            Copy.agents(working_copy),
            {__MODULE__, agent_id: agent_id, socket: socket, working_copy: working_copy}
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
      generation: Ecto.UUID.generate(),
      # In-process callers (tests) may answer the mailbox themselves.
      mailbox: Keyword.get(opts, :mailbox, &Channel.mailbox/2),
      report: Keyword.get(opts, :report, &Channel.report_turn_event/3)
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
  def handle_call({:socket, socket}, _from, state), do: {:reply, :ok, %{state | socket: socket}}

  @impl true
  def handle_info(:mailbox_ready, state) do
    report(state, %{event: :mailbox_ready, generation: state.generation, ref: nil})
    {:noreply, state}
  end

  # The session gone is the agent gone: its socket stops answering when
  # Claude Code exits, and `Liveness` reports the down.
  def handle_info(:check, state) do
    case connect(state.socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        schedule_check()
        {:noreply, state}

      {:error, reason} ->
        Logger.info("[CmsHarness] terminal agent #{state.agent_id} gone: #{inspect(reason)}")
        {:stop, :normal, state}
    end
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

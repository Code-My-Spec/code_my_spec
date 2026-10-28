defmodule CmsHarness.Agents.ATerminalAgentWritesToItsSessionSocketTest do
  @moduledoc """
  Story 1123: a terminal Claude Code session is told things through its own
  inbox socket. The agent on the harness consumes the mailbox entry, then
  writes one newline-delimited JSON frame — the shape Claude Code's own debug
  log documents — authenticated with the peer token the session published.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Terminal

  setup do
    # Unix socket paths are capped near 104 bytes, so not ExUnit's tmp_dir.
    dir = Path.join(System.tmp_dir!(), "ct#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, socket: Path.join(dir, "s.sock")}
  end

  # A stand-in for the session's inbox: every line written to it, to `test`.
  defp listen(socket) do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, socket}}, active: false, packet: :line])

    spawn_link(fn -> accept(listener, test) end)
    listener
  end

  defp accept(listener, test), do: accepted(:gen_tcp.accept(listener), listener, test)

  defp accepted({:ok, conn}, listener, test) do
    read(conn, test)
    accept(listener, test)
  end

  defp accepted({:error, _}, _listener, _test), do: :ok

  defp read(conn, test), do: line(:gen_tcp.recv(conn, 0, 2_000), conn, test)

  defp line({:ok, line}, conn, test) do
    send(test, {:line, Jason.decode!(line)})
    read(conn, test)
  end

  defp line({:error, _}, _conn, _test), do: :ok

  defp start_terminal(socket, extra \\ []) do
    test = self()

    mailbox = fn _root, params ->
      send(test, {:mailbox, params})
      :ok
    end

    report = fn _root, _agent, envelope -> send(test, {:reported, envelope}) end
    report_up = fn _root, agent_id -> send(test, {:reported_up, agent_id}) end

    id = Ecto.UUID.generate()

    {:ok, pid} =
      start_supervised(
        {Terminal,
         [
           agent_id: id,
           socket: socket,
           working_copy: "/workspace/terminal",
           mailbox: mailbox,
           report: report,
           report_up: report_up
         ] ++ extra}
      )

    assert_receive {:mailbox, %{"operation" => "register", "agent_id" => ^id}}
    {id, pid}
  end

  test "reattaching a terminal that closes during the session call returns session ended" do
    id = Ecto.UUID.generate()
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(CmsHarness.Registry, {:agent, id}, nil)
        send(parent, :registered)

        receive do
          {:"$gen_call", _from, {:session, _session}} -> exit(:normal)
        end
      end)

    assert_receive :registered
    assert {:error, :session_ended} = Terminal.attach(id, %{working_copy: "/workspace/terminal"})
    refute Process.alive?(pid)
  end

  test "a delivery is one user frame on the session's socket", %{socket: socket} do
    listen(socket)

    assert :ok = Terminal.deliver(socket, "hello")

    assert_receive {:line,
                    %{"type" => "user", "message" => %{"role" => "user", "content" => "hello"}}}

    refute_receive {:line, _}
  end

  test "the peer token is read from the key the session published beside its socket", %{
    dir: dir,
    socket: socket
  } do
    hash = :sha256 |> :crypto.hash(socket) |> Base.encode16(case: :lower)
    File.write!(Path.join(dir, "4242.#{hash}.key"), Jason.encode!(%{peerToken: "abc123"}))

    assert Terminal.peer_token(socket, dir) == "abc123"
    assert Terminal.peer_token(socket <> "-other", dir) == nil
  end

  test "a message is consumed from the mailbox, then written to the session", %{socket: socket} do
    listen(socket)
    {id, _pid} = start_terminal(socket)

    assert {:ok, :started} = CmsHarness.Agents.send_message(id, "ref-1", "Your blocker cleared.")

    assert_receive {:mailbox, %{"operation" => "consume", "agent_id" => ^id, "ref" => "ref-1"}}

    assert_receive {:line,
                    %{"type" => "user", "message" => %{"content" => "Your blocker cleared."}}}

    # Written is delivered: the session queues it, so the entry is settled.
    assert_receive {:reported, %{event: :delivered, ref: "ref-1"}}
  end

  test "a session is never busy and cannot be interrupted", %{socket: socket} do
    listen(socket)
    {id, _pid} = start_terminal(socket)

    assert {:ok, %{busy?: false}} = CmsHarness.Agents.status(id)
    assert {:error, :unsupported} = CmsHarness.Agents.interrupt(id)
  end

  test "the agent ends when its session's socket stops answering", %{socket: socket} do
    listener = listen(socket)
    {_id, pid} = start_terminal(socket)
    ref = Process.monitor(pid)

    :gen_tcp.close(listener)
    File.rm(socket)
    send(pid, :check)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  # Story 1127: a turn is the session's own hooks; Claude Code's agent list is
  # read for presence only.
  defp listed(status_fun) do
    fn -> {:ok, status_fun.()} end
  end

  defp session(status), do: [%{"sessionId" => "cc-1", "status" => status, "pid" => 4242}]

  test "a prompt submitted starts a turn, and a stop that lets the session end ends it",
       %{socket: socket} do
    listen(socket)

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(fn -> session("idle") end))

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})
    assert_receive {:reported, %{event: :turn_started}}

    send(pid, {:hook, "stop", %{}, %{}})
    assert_receive {:reported, %{event: :turn_over, ref: nil}}
  end

  test "a stop the server blocks leaves the turn open", %{socket: socket} do
    listen(socket)

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(fn -> session("idle") end))

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})
    assert_receive {:reported, %{event: :turn_started}}

    send(pid, {:hook, "stop", %{}, %{"decision" => "block"}})
    refute_receive {:reported, %{event: :turn_over}}, 100
  end

  test "Claude Code listing the session busy is not a turn: hooks alone say so", %{socket: socket} do
    listen(socket)

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(fn -> session("busy") end))

    send(pid, :check)
    refute_receive {:reported, %{event: :turn_started}}, 100
  end

  test "a tool call is the tool the session is running until it ends", %{socket: socket} do
    listen(socket)

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(fn -> session("idle") end))

    send(
      pid,
      {:hook, "pre-tool-use",
       %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}}, %{}}
    )

    assert_receive {:reported, %{event: :tool_activity, payload: %{name: "Bash"}}}

    send(pid, {:hook, "post-tool-use", %{}, %{}})
    assert_receive {:reported, %{event: :tool_activity, payload: nil}}
  end

  test "a permission prompt is the session waiting on its person", %{socket: socket} do
    listen(socket)

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(fn -> session("idle") end))

    send(pid, {:hook, "notification", %{"notification_type" => "permission_prompt"}, %{}})
    assert_receive {:reported, %{event: :waiting}}
  end

  # Issue d12aa283: a re-attach's own Liveness notification is the only time
  # the server is told this agent is up, and if that one notification is
  # ever missed the cockpit shows it `starting` forever. These are the two
  # points that now confirm it directly, bypassing Liveness entirely.
  test "attaching reports the agent up, directly", %{socket: socket} do
    listen(socket)
    {id, _pid} = start_terminal(socket)

    assert_receive {:reported_up, ^id}
  end

  test "a turn starting reports the agent up again, as a second confirmation", %{
    socket: socket
  } do
    listen(socket)
    now = fn -> session("idle") end
    {id, pid} = start_terminal(socket, session_id: "cc-1", sessions: listed(now))

    assert_receive {:reported_up, ^id}, 100

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})
    assert_receive {:reported, %{event: :turn_started}}
    assert_receive {:reported_up, ^id}
  end

  # Issue c67e1ab7: a process that survives the harness's own restart (found
  # already running by `attach/2`, via `CmsHarness.Agents.whereis/1`) never
  # reaches `init/1` on re-attach, and `settle_turn/2`'s no-op clause
  # (`%{busy?: busy?} = state, busy?`) only reports on a genuine idle/busy
  # transition -- an agent that was already busy and stays busy straight
  # through the restart has neither, so nothing else would ever re-announce
  # it. A fresh `{:session, ...}` arriving here -- a re-attach, every time --
  # must report unconditionally, independent of busy? or any transition.
  test "a re-attach while continuously busy, with no transition, still reports up", %{
    socket: socket
  } do
    listen(socket)
    now = fn -> session("idle") end
    {id, pid} = start_terminal(socket, session_id: "cc-1", sessions: listed(now))

    assert_receive {:reported_up, ^id}, 100

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})
    assert_receive {:reported, %{event: :turn_started}}
    assert_receive {:reported_up, ^id}

    assert :ok = GenServer.call(pid, {:session, %{socket: socket}})

    assert_receive {:reported_up, ^id},
                   100

    refute_receive {:reported, %{event: :turn_started}}, 50
  end

  test "its session leaving the list ends the agent, its turn settled first", %{socket: socket} do
    listen(socket)
    gone = :counters.new(1, [])
    lists = {session("idle"), []}
    now = fn -> elem(lists, :counters.get(gone, 1)) end
    {_id, pid} = start_terminal(socket, session_id: "cc-1", sessions: listed(now))
    ref = Process.monitor(pid)

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})
    assert_receive {:reported, %{event: :turn_started}}

    :counters.put(gone, 1, 1)
    send(pid, :check)

    assert_receive {:reported, %{event: :turn_over, ref: nil}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "what its session writes in a turn is reported, and its usage when the turn ends", %{
    dir: dir,
    socket: socket
  } do
    listen(socket)
    transcript = Path.join(dir, "s.jsonl")
    File.write!(transcript, "")
    now = fn -> session("idle") end

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(now), transcript: transcript)

    send(pid, {:hook, "user-prompt-submit", %{}, %{}})

    File.write!(
      transcript,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "id" => "msg_1",
          "model" => "claude-opus-5-5",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
          "content" => [%{"type" => "text", "text" => "On it."}]
        }
      }) <> "\n"
    )

    send(pid, :check)
    assert_receive {:reported, %{event: :message, text: "On it."}}, 5_000

    send(pid, {:hook, "stop", %{}, %{}})

    assert_receive {:reported,
                    %{
                      event: :turn_usage,
                      usage: %{"output_tokens" => 2, "model" => "claude-opus-5-5"}
                    }},
                   5_000
  end

  test "a session's socket and status are read from Claude Code's own session registry", %{
    dir: dir
  } do
    File.write!(
      Path.join(dir, "4242.json"),
      Jason.encode!(%{
        "pid" => 4242,
        "sessionId" => "cc-registry",
        "status" => "busy",
        "messagingSocketPath" => "/tmp/cc-socks/4242.sock"
      })
    )

    assert %{"messagingSocketPath" => "/tmp/cc-socks/4242.sock", "status" => "busy"} =
             Terminal.session_record("cc-registry", dir)

    assert Terminal.session_record("cc-elsewhere", dir) == nil
  end

  # Seen live: Claude Code 2.1.293 left a stray brace after the object.
  test "a registry file with junk after its object is still read", %{dir: dir} do
    record = %{"sessionId" => "cc-trailing", "messagingSocketPath" => "/tmp/cc-socks/1.sock"}
    File.write!(Path.join(dir, "1.json"), Jason.encode!(record) <> "}")

    assert %{"messagingSocketPath" => "/tmp/cc-socks/1.sock"} =
             Terminal.session_record("cc-trailing", dir)
  end

  # Issue d12aa283: a resumed session's old pid can leave its file behind,
  # freezing "busy" forever if a stale duplicate ever won the lookup -- the
  # turn it belongs to would never be seen to end.
  test "a stale duplicate registry file for the same session does not win over the live one",
       %{dir: dir} do
    stale_path = Path.join(dir, "1.json")
    live_path = Path.join(dir, "4242.json")

    File.write!(
      stale_path,
      Jason.encode!(%{"sessionId" => "cc-dup", "status" => "busy", "pid" => 1})
    )

    File.touch!(stale_path, {{2020, 1, 1}, {0, 0, 0}})

    File.write!(
      live_path,
      Jason.encode!(%{"sessionId" => "cc-dup", "status" => "busy", "pid" => 4242})
    )

    File.touch!(live_path, {{2024, 1, 1}, {0, 0, 1}})

    assert %{"pid" => 4242, "status" => "busy"} = Terminal.session_record("cc-dup", dir)

    File.write!(
      live_path,
      Jason.encode!(%{"sessionId" => "cc-dup", "status" => "idle", "pid" => 4242})
    )

    File.touch!(live_path, {{2024, 1, 1}, {0, 0, 2}})

    assert %{"pid" => 4242, "status" => "idle"} = Terminal.session_record("cc-dup", dir)
  end

  # A reconnect re-attaches every terminal agent whose session record survives;
  # one whose session already ended went up, then down at its first check.
  test "a terminal agent whose session already ended never starts or reports up", %{
    socket: socket
  } do
    test = self()

    assert :ignore =
             Terminal.start_link(
               agent_id: Ecto.UUID.generate(),
               socket: socket,
               session_id: "ended-session",
               working_copy: "/workspace/terminal",
               sessions: fn -> {:ok, []} end,
               report_up: fn _root, agent_id -> send(test, {:reported_up, agent_id}) end
             )

    refute_received {:reported_up, _}
  end
end

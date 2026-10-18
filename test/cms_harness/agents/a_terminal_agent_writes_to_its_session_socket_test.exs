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

    id = Ecto.UUID.generate()

    {:ok, pid} =
      start_supervised(
        {Terminal,
         [
           agent_id: id,
           socket: socket,
           working_copy: "/workspace/terminal",
           mailbox: mailbox,
           report: report
         ] ++ extra}
      )

    assert_receive {:mailbox, %{"operation" => "register", "agent_id" => ^id}}
    {id, pid}
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

  # Story 1124: the session's state is read from Claude Code's own agent list.
  defp listed(status_fun) do
    fn -> {:ok, status_fun.()} end
  end

  defp session(status), do: [%{"sessionId" => "cc-1", "status" => status, "pid" => 4242}]

  test "its session going busy starts a turn, and going idle ends it", %{socket: socket} do
    listen(socket)
    status = :counters.new(1, [])
    statuses = {"idle", "busy"}
    now = fn -> session(elem(statuses, :counters.get(status, 1))) end
    {_id, pid} = start_terminal(socket, session_id: "cc-1", sessions: listed(now))

    :counters.put(status, 1, 1)
    send(pid, :check)
    assert_receive {:reported, %{event: :turn_started}}

    :counters.put(status, 1, 0)
    send(pid, :check)
    assert_receive {:reported, %{event: :turn_over, ref: nil}}
  end

  test "its session leaving the list ends the agent, its turn settled first", %{socket: socket} do
    listen(socket)
    gone = :counters.new(1, [])
    lists = {session("busy"), []}
    now = fn -> elem(lists, :counters.get(gone, 1)) end
    {_id, pid} = start_terminal(socket, session_id: "cc-1", sessions: listed(now))
    ref = Process.monitor(pid)

    send(pid, :check)
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
    status = :counters.new(1, [])
    statuses = {"idle", "busy"}
    now = fn -> session(elem(statuses, :counters.get(status, 1))) end

    {_id, pid} =
      start_terminal(socket, session_id: "cc-1", sessions: listed(now), transcript: transcript)

    :counters.put(status, 1, 1)

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
    assert_receive {:reported, %{event: :message, text: "On it."}}

    :counters.put(status, 1, 0)
    send(pid, :check)

    assert_receive {:reported,
                    %{
                      event: :turn_usage,
                      usage: %{"output_tokens" => 2, "model" => "claude-opus-5-5"}
                    }}
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
end

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

  defp start_terminal(socket) do
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
         agent_id: id,
         socket: socket,
         working_copy: "/workspace/terminal",
         mailbox: mailbox,
         report: report}
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
end

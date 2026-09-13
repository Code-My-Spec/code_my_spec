defmodule CmsHarness.Mcp.Transport.ALeakedClientTakesItsSupervisorWithItTest do
  @moduledoc """
  Clearing a leaked MCP client frees the name, and keeps it free.

  Issue `dfa1ee9e`. `connect/2` unlinks the client's supervisor on purpose, so a
  stopped agent leaves a client registered under a name the next launch needs.
  `replace_leaked/4` exists to clear it, and it was clearing the wrong process:
  `{:already_started, pid}` names the *client*, and `anubis_mcp` starts that
  client under a supervisor whose strategy is `:one_for_all` and whose children
  take the default `:permanent` restart. Stopping the child is an instruction to
  that supervisor to put a fresh one back under the same name.

  So the relaunch raced the restart. When it lost — likelier on a loaded box —
  `start_client/3` saw a second collision it only matches on the first attempt,
  `Engine.init/1` read it as a start failure, and the agent sat at `:starting`
  with `os_pid: nil` for twelve minutes with nothing retrying, after
  `restart_agent/2` had already answered `{:ok, agent}`.

  Tested against a supervisor of that shape rather than against a live MCP
  server. What fails here is an OTP restart strategy; anubis's own client
  supervisor (`deps/anubis_mcp/lib/anubis/client/supervisor.ex`) is three lines
  of `Supervisor.init(children, strategy: :one_for_all)` over `:permanent`
  children, and reproducing it needs exactly that and nothing else.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Mcp.Transport.Anubis

  defmodule Holder do
    @moduledoc false
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)

    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  # What `Anubis.Client.start_link/1` builds: an anonymous supervisor — anonymous
  # because `derive_supervisor_name/1` only names one for an atom client name and
  # ours is a `:via` tuple — holding a `:permanent` child under the registered
  # name, `:one_for_all`.
  defmodule LeakedTree do
    @moduledoc false
    use Supervisor

    def start_link(name), do: Supervisor.start_link(__MODULE__, name)

    @impl true
    def init(name) do
      Supervisor.init([%{id: :holder, start: {Holder, :start_link, [name]}}],
        strategy: :one_for_all
      )
    end
  end

  setup do
    name =
      {:via, Registry, {CmsHarness.Registry, {:mcp, "agent-#{System.unique_integer()}", "u"}}}

    {:ok, tree} = LeakedTree.start_link(name)
    on_exit(fn -> stop(tree) end)

    %{name: name, tree: tree, client: GenServer.whereis(name)}
  end

  defp stop(pid) do
    Process.alive?(pid) && Supervisor.stop(pid, :normal, 1_000)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  test "the name is free afterwards", %{name: name, client: client} do
    assert is_pid(client), "the premise failed: nothing holds the name this test is about"

    :ok = Anubis.stop_leaked(client)

    assert await_released(name) == nil, """
    The leaked client's supervisor restarted it under the same name, so the
    relaunch that follows collides again — uncaught, because start_client/3 only
    matches the collision on its first attempt (dfa1ee9e).
    """
  end

  test "and the supervisor that would have put it back is gone too", %{
    client: client,
    tree: tree
  } do
    :ok = Anubis.stop_leaked(client)

    refute Process.alive?(tree), """
    The child went and its supervisor did not, which is the state that refills
    the name a moment later. Stopping the client is a request to that supervisor
    to replace it.
    """
  end

  test "a client nothing supervises is stopped on its own", %{name: name, tree: tree} do
    :ok = Supervisor.stop(tree, :normal, 1_000)
    assert await_released(name) == nil

    {:ok, orphan} = Holder.start_link(name)
    # Unlinked the way `connect/2` unlinks a real client, so the test process
    # does not inherit whatever exit clearing it produces.
    Process.unlink(orphan)

    :ok = Anubis.stop_leaked(orphan)

    assert await_released(name) == nil,
           "an unsupervised holder has no parent to stop instead, so it is the thing to stop"
  end

  # The `Registry` drops its entry when it sees the exit, one message after the
  # process is gone — the same wait `replace_leaked/4` does before linking.
  defp await_released(name, attempts \\ 50)
  defp await_released(_name, 0), do: :still_held

  defp await_released(name, attempts) do
    name |> GenServer.whereis() |> retry_until_released(name, attempts)
  end

  defp retry_until_released(nil, _name, _attempts), do: nil

  defp retry_until_released(_pid, name, attempts) do
    Process.sleep(10)
    await_released(name, attempts - 1)
  end
end

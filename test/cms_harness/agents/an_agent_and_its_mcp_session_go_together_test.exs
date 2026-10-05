defmodule CmsHarness.Agents.AnAgentAndItsMcpSessionGoTogetherTest do
  @moduledoc """
  Phase 2b: an agent's MCP session is a child of its `Engine.Keeper`, ahead of
  the engine. The engine holds the session's client, a dead session restarts
  the engine with a fresh one, and a session that cannot connect fails the
  start rather than leaving an agent running with no tools.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Engine
  alias CmsHarness.Agents.Liveness
  alias CmsHarness.Mcp.Session
  alias CmsHarnessTest.Machine

  defmodule Unreachable do
    @moduledoc false
    @behaviour CmsHarness.Mcp.Transport

    @impl true
    def connect(_name, _opts), do: {:error, :no_credential}
    @impl true
    def call(_client, _tool, _arguments), do: {:error, :unreachable}
    @impl true
    def call(_client, _tool, _arguments, _opts), do: {:error, :unreachable}
    @impl true
    def list_tool_names(_client), do: {:ok, []}
    @impl true
    def list_tools(_client), do: {:ok, []}
    @impl true
    def disconnect(_client), do: :ok
  end

  setup do
    {:ok, root} = Briefly.create(directory: true)
    :ok = Liveness.subscribe()
    %{root: Path.expand(root), id: Ecto.UUID.generate()}
  end

  defp started(ctx) do
    {:ok, _} = Machine.start_agent(ctx.id, ctx.root)
    on_exit(fn -> Machine.stop_agent(ctx.id) end)
    id = ctx.id
    root = ctx.root
    assert_receive {:agent_liveness, :up, ^id, ^root, nil}
  end

  defp session(id) do
    [{pid, _client}] = Registry.lookup(CmsHarness.Registry, {:mcp_session, id})
    pid
  end

  test "the engine holds its session's client", ctx do
    started(ctx)

    assert client = Session.client(ctx.id)
    assert Engine.mcp_client(ctx.id) == client
  end

  test "a dead session restarts the engine with a fresh one", ctx do
    started(ctx)
    before = session(ctx.id)

    Process.exit(before, :kill)

    id = ctx.id
    root = ctx.root
    assert_receive {:agent_liveness, :down, ^id, ^root, _reason}
    assert_receive {:agent_liveness, :up, ^id, ^root, nil}, 2_000

    refute session(ctx.id) == before
    assert Engine.mcp_client(ctx.id) == Session.client(ctx.id)
  end

  test "a session that cannot connect fails the start", ctx do
    previous = Application.get_env(:code_my_spec, :harness_mcp_transport)
    Application.put_env(:code_my_spec, :harness_mcp_transport, Unreachable)
    on_exit(fn -> Application.put_env(:code_my_spec, :harness_mcp_transport, previous) end)

    assert {:error, reason} = Machine.start_agent(ctx.id, ctx.root)
    assert inspect(reason) =~ "no_credential"
    refute Machine.running?(ctx.id)
  end
end

defmodule CodeMySpecWeb.ATerminalAgentIsReattachedNotLaunchedTest do
  @moduledoc """
  Story 1124: when a harness reconnects and asks which agents to restore, a
  terminal Claude Code session is a person's process, never one the harness
  launches. It comes back as an agent to re-attach by its session id; only the
  agents we run come back as launches (found 2026-10-18: a restart would have
  started every on-duty terminal agent as an Alloy engine).
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpec.DevicesFixtures
  import Phoenix.ChannelTest, except: [push: 3]

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    Sandbox.mode(Repo, {:shared, self()})
    RecordingAgentTransport.listen(ctx)

    {:ok, _reply, socket} =
      UserSocket
      |> socket("reattach", %{scope: ctx.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{ctx.scope.active_project_id}",
        %{
          "label" => "the harness that just restarted",
          "harness_id" => ctx.scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(ctx.scope).id}
        }
      )

    Map.put(ctx, :socket, socket)
  end

  test "a terminal agent comes back to re-attach by its session id, not to launch", ctx do
    {:ok, ours} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        working_copy: "/tmp/reattach-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    session = "cc-#{System.unique_integer([:positive])}"
    {:ok, terminal} = Agents.register_terminal(ctx.scope, session)

    ref = Phoenix.ChannelTest.push(ctx.socket, "agents_to_restore", %{})
    assert_receive %Phoenix.Socket.Reply{ref: ^ref, status: :ok, payload: reply}, 2_000
    %{"agents" => agents, "terminals" => terminals} = reply

    launched = Enum.map(agents, & &1["agent_id"])
    assert ours.id in launched
    refute terminal.id in launched

    assert %{"agent_id" => terminal.id, "session_id" => session} in terminals
  end
end

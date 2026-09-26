defmodule CodeMySpec.MainAgent.TheCadenceDeliversATurnTest do
  @moduledoc """
  The tick has to reach the agent, not just move `last_check`.

  `2c34da87`, reported by a main agent measuring its own cadence: the timer
  fired and no turn arrived. `check_in/1` returned the report to its caller, and
  from the timer that caller was the `Cadence` process, which dropped it.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.MainAgent.Cadence
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    :ok
  end

  defp main_agent(scope) do
    # `Agents.main_agent/1` resolves through `WorkingCopies.main/1`; the fixture's
    # copy is not flagged, so nothing would be found to deliver to.
    {1, _} =
      Repo.update_all(
        from(w in WorkingCopy, where: w.id == ^scope.active_working_copy_id),
        set: [main: true]
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        role: "main",
        status: :running,
        continuous: false,
        provider: "anthropic",
        engine: :alloy,
        working_copy: "/tmp/cadence-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  test "a tick delivers the digest to the project's main agent" do
    scope = full_scope_fixture()
    main = main_agent(scope)

    assert Agents.main_agent(scope), "main_agent/1 cannot find the agent"

    {:ok, pid} = Cadence.start_link(scope)
    send(pid, :check_in)

    assert_receive {:agent_message, id, text}, 5_000

    assert id == main.id, """
    The tick reached the transport but addressed the wrong agent.
    """

    assert is_binary(text) and text != "", """
    The digest arrived empty. An empty check-in reads as all-quiet, which is the
    reassuring answer, so it must not be what a tick sends by default.
    """
  end

  test "a stood-down project's tick delivers nothing" do
    scope = full_scope_fixture()
    _main = main_agent(scope)
    :ok = Cadence.stand_down(scope)

    {:ok, pid} = Cadence.start_link(scope)
    send(pid, :check_in)

    refute_receive {:agent_message, _id, _text}, 1_000
  end
end

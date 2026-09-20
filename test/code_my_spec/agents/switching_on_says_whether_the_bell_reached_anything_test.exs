defmodule CodeMySpec.Agents.SwitchingOnSaysWhetherTheBellReachedAnythingTest do
  @moduledoc """
  Switching continuous on is not one outcome.

  An agent with eligible work takes a turn now; an agent with none sits exactly
  as it did. Both used to answer `:enabled`, and the tool rendered the same
  sentence for each — so an operator asking "why are my agents not running",
  which is the confusion the tool exists to resolve, had to make a second call
  to find out which had happened.

  Measured live by QA on story 796 (`fe059aa3`): two enables, one that admitted
  a turn and one that admitted nothing, indistinguishable from the reply.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: false,
        working_copy: "/tmp/bell-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  test "an agent with nothing to do is told nothing was requested", ctx do
    # A bare fixture project: the serial chain is unsatisfied, so no coding-role
    # requirement is actionable and this agent is eligible for nothing.
    assert {:ok, _agent, :enabled_without_work} =
             Agents.set_agent_continuous(ctx.scope, ctx.agent.id, true),
           "switching on reported a turn that was never requested"

    refute_receive {:work_turn_requested, _id, _ref, _message}, 100
  end

  test "switching off is its own answer", ctx do
    {:ok, _, _} = Agents.set_agent_continuous(ctx.scope, ctx.agent.id, true)

    assert {:ok, agent, :paused} =
             Agents.set_agent_continuous(ctx.scope, ctx.agent.id, false)

    refute agent.continuous
  end
end

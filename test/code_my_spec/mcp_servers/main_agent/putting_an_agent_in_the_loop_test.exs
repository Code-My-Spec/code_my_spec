defmodule CodeMySpec.McpServers.MainAgent.PuttingAnAgentInTheLoopTest do
  @moduledoc """
  Issue `d3660c2f`. The main agent could start, stop, restart and message its
  agents, and could not put one in the loop — so anything it started took a
  single turn and stopped. That is the difference between having agents and
  using them, and it is most of what "my agents are not running" means.

  `Agents.set_agent_continuous/3` already existed and `AgentConversationLive`
  already called it: a person could toggle this from a conversation and the main
  agent could not. The only tool that reached it was `set_working_copy_loop`,
  which is the wrong grain twice — per working copy, so it starts every role on
  that copy, and on the product role rather than main.

  ## What the answer has to say

  Not "ok". Switching on is a flag *and* a nudge and they can disagree: the flag
  always lands, the nudge reaches a process that may not be there. `status:
  running` is not evidence — it is written on a clean start and a clean stop, so
  a harness restart leaves a row claiming life indefinitely. Reporting success
  for the flag while the nudge reached nobody is how a fleet comes to look busy
  and do nothing, which is the failure this tool exists inside of.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous

  defp text(response) do
    response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
  end

  defp an_agent(scope) do
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
        working_copy_id: copy.id,
        working_copy: "/tmp/loop-#{System.unique_integer([:positive])}"
      })

    agent
  end

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}, agent: an_agent(scope)}
  end

  test "switching one off says it will stop, and does not claim to have sent anything", ctx do
    {:reply, response, _} =
      SetAgentContinuous.execute(%{agent_id: ctx.agent.id, continuous: false}, ctx.frame)

    refute response.isError, text(response)
    said = text(response)

    assert said =~ "Out of the loop",
           "switching off has to say so plainly. Got: #{said}"

    assert Repo.get(CodeMySpec.Agents.Agent, ctx.agent.id).continuous == false,
           "the flag is the part that always lands; it did not"
  end

  test "an agent with nothing behind it is not reported as running", ctx do
    # Nothing is serving this agent's working copy — no harness, no process. The
    # flag will land and the nudge cannot.
    {:reply, response, _} =
      SetAgentContinuous.execute(%{agent_id: ctx.agent.id, continuous: true}, ctx.frame)

    said = text(response)

    refute said =~ "has been nudged",
           """
           An agent with no process behind it was reported as nudged and working.

           That is the reported failure in miniature: the flag lands, the bell
           rings into nothing, and every surface then shows a healthy agent that
           will never take a turn.

           Got: #{said}
           """

    assert response.isError or said =~ "restart",
           """
           The answer neither refused nor said a restart was involved, so the
           caller cannot tell whether this agent will actually work.

           Got: #{said}
           """
  end

  test "an id that is not an agent on this project is refused, not answered", ctx do
    {:reply, response, _} =
      SetAgentContinuous.execute(
        %{agent_id: Ecto.UUID.generate(), continuous: true},
        ctx.frame
      )

    assert response.isError,
           """
           An unknown agent id was answered rather than refused.

           A silent success here is worse than an error: the caller believes a
           fleet member is now working when no such agent exists.
           """
  end
end

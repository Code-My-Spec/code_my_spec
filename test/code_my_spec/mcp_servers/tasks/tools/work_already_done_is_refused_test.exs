defmodule CodeMySpec.McpServers.Tasks.Tools.WorkAlreadyDoneIsRefusedTest do
  @moduledoc """
  `start_task` refuses a requirement that is already satisfied, even when the
  graph still offers it (67e6b5cb).

  The graph lags a write that does not announce. The 1118 `story_promoted`
  repeats offered done work over and over, and eval probe 1870's agent spent a
  turn on a story already certified. Asking the story itself, before taking the
  work, is what ends that.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Requirements
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    scope = %{scope | active_working_copy_id: copy.id}
    story = story_fixture(scope, %{ready_for_dev: true})
    Requirements.recompute(scope)
    %{scope: scope, story: story}
  end

  defp coder(ctx) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        status: :running,
        working_copy: "/tmp/done-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp start(ctx, agent \\ nil) do
    agent = agent || coder(ctx)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: agent.id}}

    {:reply, response, _} =
      StartTask.execute(
        %{
          entity_type: "story",
          entity_id: to_string(ctx.story.number),
          requirement_name: "component_linked"
        },
        frame
      )

    {response.isError, hd(Response.to_protocol(response)["content"])["text"]}
  end

  test "work done behind the graph's back is refused, pointing at reject_offer", ctx do
    component = component_fixture(ctx.scope)

    # Linked without announcing, so the graph still offers it — the stale offer.
    {:ok, _} = ctx.story |> Ecto.Changeset.change(component_id: component.id) |> Repo.update()

    agent = coder(ctx)

    # The real push path (Work.node_key/2) keys a story's offer on its public
    # number, not its database id -- matching that here, not ctx.story.id,
    # is what close_stale_offer/2 (start_task.ex) now resolves against too.
    offered =
      Offers.record(
        nil,
        agent,
        :work,
        {"requirement", "story:#{ctx.story.number}:component_linked"}
      )

    assert {true, text} = start(ctx, agent)
    assert text =~ "already satisfied"
    assert text =~ "the offer of it is closed"

    assert %{status: :declined, reason: "already satisfied"} =
             CodeMySpec.Repo.get!(CodeMySpec.Agents.Offer, offered.id)
  end

  test "work not yet done is started as before", ctx do
    assert {false, _text} = start(ctx)
  end
end

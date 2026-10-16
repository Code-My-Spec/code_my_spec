defmodule CodeMySpec.McpServers.Tasks.Tools.StartTaskStoryIdentityTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.ComponentsFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.{Agent, AgentsRepository}
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{Directives, RequirementGraph}
  alias CodeMySpec.Stories
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = working_copy_scope_fixture()
    component = component_fixture(scope)
    other = story_fixture(scope, %{title: "Other numbered story", component_id: component.id})

    target =
      story_fixture(scope, %{title: "Requested Three Amigos story", component_id: component.id})

    other = other |> Ecto.Changeset.change(number: target.id + 1_000_000) |> Repo.update!()
    target = target |> Ecto.Changeset.change(number: other.id) |> Repo.update!()
    Requirements.recompute(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        status: :running,
        working_copy: scope.cwd,
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    %{scope: scope, target: target, other: other, agent: agent, frame: frame}
  end

  test "Three Amigos opens the story number emitted by the graph despite an ID collision", ctx do
    assert ctx.target.number == ctx.other.id
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(ctx.scope)

    node =
      Enum.find(nodes, fn node ->
        node.entity_type == "story" and node.name == "three_amigos_complete" and
          to_string(node.entity_id) == to_string(ctx.target.id)
      end)

    assert node
    [offered] = Directives.number_nodes(ctx.scope, [node])
    reference = Directives.entity_ref(offered)
    assert reference == ctx.target.number

    {response, text} = start(ctx, reference, "three_amigos_complete")
    refute response.isError, text
    assert text =~ ctx.target.title
    refute text =~ ctx.other.title
    task = Agent.active_task(Repo.get!(Agent, ctx.agent.id))
    assert task.story_id == ctx.target.id
    assert task.requirement_name == "three_amigos_complete"
  end

  test "a missing requirement names the requested number rather than the internal ID", ctx do
    refute ctx.target.number == ctx.target.id
    {response, text} = start(ctx, ctx.target.number, "missing_requirement")
    assert response.isError
    assert text =~ "Requirement missing_requirement not found for story #{ctx.target.number}"
    refute text =~ "Requirement missing_requirement not found for story #{ctx.target.id}"
    assert Agent.active_task(Repo.get!(Agent, ctx.agent.id)) == nil
  end

  test "an existing database ID cannot substitute for a nonexistent story number", ctx do
    assert Stories.get_story_by_number(ctx.scope, ctx.target.id) == nil
    assert Stories.get_story(ctx.scope, ctx.target.id).id == ctx.target.id
    {response, text} = start(ctx, ctx.target.id, "three_amigos_complete")
    assert response.isError
    assert text =~ "Story #{ctx.target.id} not found"
    assert Agent.active_task(Repo.get!(Agent, ctx.agent.id)) == nil
  end

  defp start(ctx, reference, requirement) do
    {:reply, response, _} =
      StartTask.execute(
        %{
          entity_type: "story",
          entity_id: to_string(reference),
          requirement_name: requirement
        },
        ctx.frame
      )

    {response, hd(Response.to_protocol(response)["content"])["text"]}
  end
end

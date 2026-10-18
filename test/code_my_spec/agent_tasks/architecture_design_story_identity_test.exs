defmodule CodeMySpec.AgentTasks.ArchitectureDesignStoryIdentityTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.ComponentsFixtures

  alias Anubis.Server.{Frame}
  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Agents.{Agent, AgentsRepository}
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{Directives, RequirementGraph}
  alias CodeMySpecTest.AgentPresence

  setup do
    root = CodeMySpec.TempFile.owned_dir("architecture_identity")
    scope = put_fixture_environment(working_copy_scope_fixture(), Environment.new(:local, root))
    component = component_fixture(scope)
    other = story_fixture(scope, %{title: "Other collision story"})
    target = story_fixture(scope, %{title: "Requested architecture story"})
    target = target |> Ecto.Changeset.change(number: other.id) |> Repo.update!()
    Requirements.recompute(scope)
    %{scope: scope, component: component, other: other, target: target}
  end

  test "the offered number selects one story for dispatch and evaluation", ctx do
    assert ctx.target.number == ctx.other.id
    refute ctx.target.id == ctx.other.id
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(ctx.scope)

    node =
      Enum.find(nodes, fn node ->
        node.entity_type == "story" and node.name == "component_linked" and
          to_string(node.entity_id) == to_string(ctx.target.id)
      end)

    assert node
    [offered] = Directives.number_nodes(ctx.scope, [node])
    assert Directives.entity_ref(offered) == ctx.target.number

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        status: :running,
        working_copy: ctx.scope.cwd,
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: agent.id}}

    response =
      ToolLibrary.run(
        "start_task",
        %{
          entity_type: "story",
          entity_id: to_string(Directives.entity_ref(offered)),
          requirement_name: "component_linked"
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert {:ok, prompt} = response
    assert prompt =~ ctx.target.title
    refute prompt =~ ctx.other.title

    task = Agent.active_task(Repo.get!(Agent, agent.id))
    assert task.story_id == ctx.target.id
    ctx.other |> Ecto.Changeset.change(component_id: ctx.component.id) |> Repo.update!()
    assert {:ok, :invalid, feedback} = ArchitectureDesign.evaluate(ctx.scope, task)
    assert feedback =~ "Story #{ctx.target.number} is not linked"

    ctx.target |> Ecto.Changeset.change(component_id: ctx.component.id) |> Repo.update!()
    assert {:ok, :valid} = ArchitectureDesign.evaluate(ctx.scope, task)
  end

  test "a missing task story does not fall back to a matching number", ctx do
    task = %{story_id: ctx.target.id}
    ctx.other |> Ecto.Changeset.change(number: ctx.target.id) |> Repo.update!()
    Repo.delete!(ctx.target)
    assert {:error, :story_not_found} = ArchitectureDesign.command(ctx.scope, task)
    assert {:ok, _} = ArchitectureDesign.command(ctx.scope, %{})
    assert {:error, :story_not_found} = ArchitectureDesign.evaluate(ctx.scope, task)
  end
end

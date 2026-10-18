defmodule CodeMySpec.Agents.ProductSeesEveryStoryTest do
  @moduledoc """
  a31f1cd6 step 4d. Product owns all triage, three amigos and story design and
  lives on the main copy, so its work covers every story in the project wherever
  the story is placed. Coding and QA stay on their own copy's stories.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Menu
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    feature = scope.active_working_copy_id
    main = issue_copy(scope)
    {:ok, _} = CodeMySpec.Staffing.designate_main(scope, main.id)
    other = issue_copy(scope)

    component = component_fixture(scope)
    story = scope |> story_fixture(%{component_id: component.id}) |> place(feature)

    main_scope = %{scope | active_working_copy_id: main.id}
    other_scope = %{scope | active_working_copy_id: other.id}

    %{
      scope: scope,
      main_scope: main_scope,
      other_scope: other_scope,
      story: story,
      product: agent(main_scope, :product),
      coding: agent(other_scope, :coding)
    }
  end

  describe "a story placed on a feature copy with an untriaged issue" do
    setup ctx do
      issue_fixture(ctx.scope, %{story_id: ctx.story.id})
      project(ctx)
      :ok
    end

    test "product on the main copy is offered its triage", ctx do
      assert offered?(ctx.main_scope, ctx.product, "story_issues_triaged", ctx.story)
    end

    test "get_next_requirement counts it in product's wave", ctx do
      claimable = Work.claimable_work(ctx.main_scope, ctx.product)
      text = next(ctx.main_scope, ctx.product)

      assert text =~ "- #{hd(claimable).name} ("
      assert text =~ "Remaining: #{length(claimable) - 1}"
      assert Enum.any?(claimable, &(&1.name == "story_issues_triaged"))
    end

    test "product can start it, recorded against the story", ctx do
      {error?, text} =
        call(StartTask, ctx.main_scope, ctx.product, %{
          requirement_name: "story_issues_triaged",
          entity_type: "story",
          entity_id: to_string(ctx.story.number)
        })

      refute error?, text

      assert [task] = reload(ctx.product).tasks
      assert task.requirement_name == "story_issues_triaged"
      assert task.story_id == ctx.story.id
      assert task.status == :active
      assert reload(ctx.product).story_id == nil
    end

    test "claiming it does not make the placed story's epic product's design", ctx do
      {:ok, epic} = CodeMySpec.Epics.create_epic(ctx.scope, %{name: "Placed"})
      ctx.story |> Ecto.Changeset.change(epic_id: epic.id) |> Repo.update!()

      {false, _text} =
        call(StartTask, ctx.main_scope, ctx.product, %{
          requirement_name: "story_issues_triaged",
          entity_type: "story",
          entity_id: to_string(ctx.story.number)
        })

      assert reload(ctx.product).epic_id == nil
    end

    test "product's stop menu counts it", ctx do
      claimable = Work.claimable_work(ctx.main_scope, ctx.product)
      menu = ctx.main_scope |> Menu.live(:product, ctx.product) |> Keyword.get(:requirements, 0)

      assert menu == length(claimable)
      assert Enum.any?(claimable, &(&1.name == "story_issues_triaged"))
    end

    test "coding on another copy is not offered the story", ctx do
      refute Enum.any?(
               Work.claimable_work(ctx.other_scope, ctx.coding),
               &(&1.entity_type == "story" and to_string(&1.entity_id) == to_string(ctx.story.id))
             )
    end
  end

  describe "a placed story whose design is owed" do
    setup ctx do
      project(ctx)
      :ok
    end

    test "product on the main copy is offered its three amigos and can start it", ctx do
      assert offered?(ctx.main_scope, ctx.product, "three_amigos_complete", ctx.story)

      {error?, text} =
        call(StartTask, ctx.main_scope, ctx.product, %{
          requirement_name: "three_amigos_complete",
          entity_type: "story",
          entity_id: to_string(ctx.story.number)
        })

      refute error?, text
      assert [%{story_id: id}] = reload(ctx.product).tasks
      assert id == ctx.story.id
    end

    test "only product's requirements on it are offered across copies", ctx do
      ours = Requirements.Registry.requirement_names_for_role(:product)

      for node <- Work.claimable_work(ctx.main_scope, ctx.product),
          node.entity_type == "story",
          do: assert(node.name in ours, "#{node.name} is not product's")
    end

    test "coding cannot start product's work on it from another copy", ctx do
      {error?, _text} =
        call(StartTask, ctx.other_scope, ctx.coding, %{
          requirement_name: "three_amigos_complete",
          entity_type: "story",
          entity_id: to_string(ctx.story.number)
        })

      assert error?
      assert reload(ctx.coding).tasks == []
    end
  end

  defp project(ctx) do
    for scope <- [ctx.scope, ctx.main_scope, ctx.other_scope], do: Requirements.recompute(scope)
  end

  defp offered?(scope, agent, name, story) do
    scope
    |> Work.claimable_work(agent)
    |> Enum.any?(
      &(&1.name == name and &1.entity_type == "story" and
          to_string(&1.entity_id) == to_string(story.id))
    )
  end

  defp next(scope, agent) do
    {false, text} = call("get_next_requirement", scope, agent, %{})
    text
  end

  defp call(name, scope, agent, params) when is_binary(name) do
    name |> ToolLibrary.run(params, %{scope: scope, agent_id: agent.id}) |> flagged()
  end

  defp call(tool, scope, agent, params) do
    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    {:reply, response, _frame} = tool.execute(params, frame)
    {response.isError, hd(Response.to_protocol(response)["content"])["text"]}
  end

  defp flagged({:ok, text}), do: {false, text}
  defp flagged({:error, text}), do: {true, text}

  defp issue_copy(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    copy
  end

  defp place(story, copy_id),
    do: story |> Ecto.Changeset.change(working_copy_id: copy_id) |> Repo.update!()

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        continuous: true,
        working_copy: "/tmp/rp4d-#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp reload(agent), do: Repo.get!(Agent, agent.id)
end

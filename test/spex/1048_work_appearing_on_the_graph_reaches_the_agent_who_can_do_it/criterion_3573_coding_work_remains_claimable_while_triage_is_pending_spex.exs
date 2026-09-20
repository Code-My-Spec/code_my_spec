defmodule CodeMySpecSpex.Story1048.Criterion3573Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3573 — Coding work remains claimable while triage is pending.

  File incoming issues through the real tool before releasing coding work.
  Follow role-local discovery through an actual coding task claim, and verify
  that doing so does not clear or assign product's triage work.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Product triage and coding eligibility are independent" do
    scenario "Coding can claim its review without clearing product triage" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3573")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3573 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        for n <- 1..3 do
          {:reply, filed, _} =
            CreateIssue.execute(
              %{
                title: "Pending product triage #{n} for criterion 3573",
                description: "An unrelated incoming issue must not block coding",
                severity: "medium"
              },
              frame(context)
            )

          refute filed.isError, response_text(filed)
        end

        :ok = Fixtures.watch_graph(context.scope)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: false)
        product_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
        {:reply, triage, _} = GetNextRequirement.execute(%{}, product_frame)
        refute triage.isError, response_text(triage)
        assert response_text(triage) =~ "issues_triaged"
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           story: story,
           product_frame: product_frame,
           coding_frame: coding_frame
         })}
      end

      when_ "releasing the story changes graph eligibility", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        {:ok, context}
      end

      then_ "coding receives one turn for its own work while triage stays with product",
            context do
        {:reply, coding, _} = GetNextRequirement.execute(%{}, context.coding_frame)
        refute coding.isError, response_text(coding)
        assert response_text(coding) =~ "bdd_specs_exist"
        refute response_text(coding) =~ "issues_triaged"

        {:reply, product, _} = GetNextRequirement.execute(%{}, context.product_frame)
        refute product.isError, response_text(product)
        assert response_text(product) =~ "issues_triaged"

        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:reply, tasks, _} = ListTasks.execute(%{}, context.coding_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end

      when_ "coding chooses its available context review", context do
        {:reply, claimed, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story.id)
            },
            context.coding_frame
          )

        refute claimed.isError, response_text(claimed)
        {:ok, context}
      end

      then_ "coding owns only the review and product triage remains outstanding", context do
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.coding_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "**bdd_specs_exist**"
        refute response_text(tasks) =~ "issues_triaged"

        {:reply, product, _} = GetNextRequirement.execute(%{}, context.product_frame)
        refute product.isError, response_text(product)
        assert response_text(product) =~ "issues_triaged"
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story538.Criterion3108Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 3108 — Unblocked role work is reconsidered through typed per-agent admission.

  Product completes a real Three Amigos task and releases the story. An
  existing continuous coding agent receives one unassigned turn, while QA
  remains idle. The agent, not the graph event, chooses the eventual task.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
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

  spex "Finishing product work offers one existing coding agent an unassigned turn" do
    scenario "The completed review and release unblock coding without staffing or claiming" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3108")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "product owns a review and idle coding and QA engines already exist", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Product-reviewed refund posting",
            description: "Coding chooses its work after product releases this story",
            acceptance_criteria: ["The refund reaches the ledger"],
            ready_for_dev: true
          )

        product = Fixtures.running_agent(context.scope, role: "product", continuous: false)
        product_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(story.id)
            },
            product_frame
          )

        refute started.isError, response_text(started)

        {:reply, parked, _} =
          UpdateStory.execute(
            %{story_id: to_string(story.id), ready_for_dev: false},
            product_frame
          )

        refute parked.isError, response_text(parked)

        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
        :ok = Fixtures.watch_graph(context.scope)
        assert Fixtures.role_queue_size(context.scope, coding.id) == 0
        assert Fixtures.role_queue_size(context.scope, qa.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()

        for id <- [coding.id, qa.id] do
          assert {:ok, _} = Machine.start_agent(id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(id) end)
        end

        {:ok,
         Map.merge(context, %{
           story: story,
           product_frame: product_frame,
           product_task_id: extract_task_id!(started),
           coding_id: coding.id,
           qa_id: qa.id,
           running_before: Enum.sort(Machine.running())
         })}
      end

      when_ "product finishes the review, evaluates its task, and releases the story", context do
        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, context.story,
            persona_id: context.persona_id
          )

        {:reply, evaluated, _} =
          EvaluateTask.execute(%{task_id: context.product_task_id}, context.product_frame)

        refute evaluated.isError, response_text(evaluated)
        assert response_text(evaluated) =~ "Passed"

        {:reply, released, _} =
          UpdateStory.execute(
            %{story_id: to_string(context.story.id), ready_for_dev: true},
            context.product_frame
          )

        refute released.isError, response_text(released)
        :ok = Fixtures.settle_graph(context.scope)
        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "only the existing eligible coding engine receives one turn and neither role gets a task assigned",
            context do
        assert Fixtures.role_queue_size(context.scope, context.coding_id) > 0
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.coding_id)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.qa_id)
        assert Enum.sort(Machine.running()) == context.running_before
        [request] = HeldProvider.seen()
        prompt = request |> Jason.decode!() |> Map.fetch!("messages") |> Jason.encode!()
        refute prompt =~ context.story.title
        refute prompt =~ "The first is:"
        refute prompt =~ "Work of your kind is available"

        for id <- [context.coding_id, context.qa_id] do
          frame = %Frame{assigns: %{current_scope: context.scope, agent_id: id}}
          {:reply, tasks, _} = ListTasks.execute(%{}, frame)
          refute tasks.isError, response_text(tasks)
          assert response_text(tasks) == "No tasks."
        end

        {:reply, product_tasks, _} = ListTasks.execute(%{}, context.product_frame)
        refute product_tasks.isError, response_text(product_tasks)
        assert response_text(product_tasks) =~ context.product_task_id
        assert response_text(product_tasks) =~ "[completed]"
        {:ok, context}
      end
    end
  end
end

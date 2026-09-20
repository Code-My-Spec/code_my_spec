defmodule CodeMySpecSpex.Story538.Criterion3104Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 3104 — A task-free stop menu names discovery tools without choosing a requirement.

  Eligible work exists before the turn boundary. Ending the turn must request
  exactly one turn from the existing engine, offering discovery and explicit
  claim tools without embedding or claiming a particular requirement.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    exunit_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Available work offers a turn without choosing the agent's task" do
    scenario "The task-free turn boundary offers discovery without selecting work" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3104")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent has no active task and released work is eligible",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3104 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, available, _} = GetNextRequirement.execute(%{}, agent_frame)
        refute available.isError, response_text(available)
        assert Fixtures.role_queue_size(context.scope, agent.id) > 0
        {:reply, tasks, _} = ListTasks.execute(%{}, agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
        {:ok, Map.merge(context, %{agent_id: agent.id, agent_frame: agent_frame, story: story})}
      end

      when_ "the agent reports its task-free turn has ended", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "one turn reaches the model without a task or embedded requirement", context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        [request] = HeldProvider.seen()
        messages = Jason.decode!(request)["messages"]
        assert is_list(messages)
        assert messages != []
        prompt = Jason.encode!(messages)
        assert prompt =~ "list_requirements"
        assert prompt =~ "get_next_requirement"
        assert prompt =~ "start_task"
        refute prompt =~ context.story.title
        refute prompt =~ context.component.module_name
        refute prompt =~ "Context design review file exists"

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, context}
      end
    end
  end
end

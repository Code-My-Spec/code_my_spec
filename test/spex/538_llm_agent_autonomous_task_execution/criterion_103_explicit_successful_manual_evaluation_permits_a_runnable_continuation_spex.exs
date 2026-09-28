defmodule CodeMySpecSpex.Story538.Criterion1494Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1494 — Explicit successful manual evaluation permits a runnable continuation.

  The operator has indicated that the specification files are ready. The
  agent explicitly evaluates its active task; only after completion and the
  turn boundary may one unassigned work turn be requested.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
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

  spex "Explicit successful evaluation permits an unassigned continuation", criterion: 103 do
    scenario "The completed task is retained and one later turn leaves the next claim to the agent" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_1494")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous agent has a ready specification task and an operator instruction to evaluate it",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Explicit completion before continuation",
            description: "Successful evaluation permits only an unassigned later turn",
            acceptance_criteria: ["The agent chooses its next task after completing this one"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            agent_frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)
        {:reply, tasks, _} = ListTasks.execute(%{}, agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ task_id

        refreshed_story = StoryHelpers.fetch(context.scope, story.id)

        Enum.each(refreshed_story.criteria, fn criterion ->
          path = Fixtures.spec_file_path(refreshed_story, criterion)

          :ok =
            Environments.write_file(context.environment, path, valid_spec_content(criterion.id))
        end)

        :ok =
          Fixtures.prior_operator_instruction(
            context.scope,
            agent,
            "The specification files are ready. Please evaluate your current task."
          )

        {:reply, available, _} = GetNextRequirement.execute(%{}, agent_frame)
        refute available.isError, response_text(available)
        assert Fixtures.role_queue_size(context.scope, agent.id) > 0

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           task_id: task_id,
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent explicitly evaluates the ready task", context do
        Fixtures.deliver_manifest(context.scope)

        {:reply, evaluated, _} =
          EvaluateTask.execute(%{task_id: context.task_id}, context.agent_frame)

        refute evaluated.isError, response_text(evaluated)
        assert response_text(evaluated) =~ "Passed"
        {:ok, context}
      end

      then_ "the task is completed without selecting its successor", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[completed]"
        refute response_text(tasks) =~ "[active]"
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, Map.put(context, :completed_tasks, response_text(tasks))}
      end

      when_ "the completed turn reaches its boundary", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        HeldProvider.await_request()
        {:ok, context}
      end

      then_ "exactly one unassigned work turn is admitted while the completed history is preserved",
            context do
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        [request] = HeldProvider.seen()
        prompt = request |> Jason.decode!() |> Map.fetch!("messages") |> Jason.encode!()
        refute prompt =~ "The first is:"
        refute prompt =~ "Context design review file exists"
        refute prompt =~ context.component.module_name

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.completed_tasks
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end

  defp valid_spec_content(criterion_id) do
    """
    defmodule MyAppSpex.Criterion#{criterion_id}Spex do
      use MyAppSpex.Case
      spex "fixture feature", criterion: #{criterion_id} do
        scenario "fixture scenario" do
          given_ "a value", context do
            {:ok, Map.put(context, :value, 1)}
          end
          when_ "it is incremented", context do
            {:ok, Map.update!(context, :value, &(&1 + 1))}
          end
          then_ "the result is two", context do
            assert context.value == 2
            {:ok, context}
          end
        end
      end
    end
    """
  end
end

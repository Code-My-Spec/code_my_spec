defmodule CodeMySpecSpex.Story538.Criterion1502Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1502 — Changed or passing evaluation resets repeated-feedback tracking.

  Five real failures establish repeated feedback. Writing one missing spec
  changes that feedback; writing the remainder makes evaluation pass. The
  stop menus must not carry the old repeated-failure warning across either
  transition, and tracking must not change continuous intent or choose work.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.Environments
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

  spex "Changed and passing evaluations clear stale repetition feedback", criterion: 110 do
    scenario "Changed missing-file feedback starts fresh and a later pass clears the warning" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_1502")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous agent owns a specification task whose files have not been written",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Keep working after failed evaluation",
            description: "Evaluation feedback must preserve the current attempt",
            acceptance_criteria: ["The agent retains the task when its specs are missing"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        task_id = extract_task_id!(started)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ task_id

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           task_id: task_id,
           story: StoryHelpers.fetch(context.scope, story.id),
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent explicitly evaluates the same unfinished task five times", context do
        evaluations =
          Enum.map(1..5, fn _ ->
            response =
              ToolLibrary.run(
                "evaluate_task",
                %{task_id: context.task_id},
                Map.put(
                  context.agent_frame.assigns,
                  :scope,
                  context.agent_frame.assigns[:current_scope]
                )
              )

            assert match?({:ok, _}, response), response_text(response)
            assert response_text(response) =~ "Needs work"
            response_text(response)
          end)

        assert length(Enum.uniq(evaluations)) == 1
        {:ok, Map.put(context, :evaluations, evaluations)}
      end

      then_ "the same task stays active and no new task or automatic model turn is admitted",
            context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end

      when_ "the agent reports the end of its turn", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "continuous remains enabled and the original attempt is still the only task",
            context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "the latest stop feedback identifies the active task and its repeated failure",
            context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        text = response_text(conversation)
        assert text =~ context.task_id
        # The menu's own sentence, not a paraphrase of it. `5.*fail` matched
        # `Criterion 147850 (Failure path)` the first time this project's
        # criterion ids reached six digits — a refute that passes or fails on
        # how many rows the suite happened to insert before it. `Validation.Menu`
        # writes "The same feedback has repeated N times", and that is the only
        # thing either half of this criterion is about.
        assert text =~ ~r/the same feedback has repeated \d+ times/i
        refute text =~ "Task completed successfully"
        {:ok, context}
      end

      when_ "one missing spec is written and the next evaluation returns different feedback",
            context do
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        HeldProvider.hold()
        [first | _rest] = context.story.criteria

        :ok =
          Environments.write_file(
            context.environment,
            Fixtures.spec_file_path(context.story, first),
            valid_spec_content(first.id)
          )

        Fixtures.deliver_manifest(context.scope)

        evaluated =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, evaluated), response_text(evaluated)
        assert response_text(evaluated) =~ "Needs work"
        refute response_text(evaluated) == hd(context.evaluations)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the changed feedback is not described as the earlier repeated failure", context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) =~ context.task_id

        refute response_text(conversation) =~ ~r/the same feedback has repeated/i

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[active]"
        {:ok, context}
      end

      when_ "the remaining files are written and explicit evaluation passes", context do
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        HeldProvider.hold()

        Enum.each(context.story.criteria, fn criterion ->
          :ok =
            Environments.write_file(
              context.environment,
              Fixtures.spec_file_path(context.story, criterion),
              valid_spec_content(criterion.id)
            )
        end)

        Fixtures.deliver_manifest(context.scope)

        evaluated =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, evaluated), response_text(evaluated)
        assert response_text(evaluated) =~ "Passed"
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent_id)
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the pass leaves no stale repetition warning or replacement task and continuous remains enabled",
            context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        # The menu's sentence, as above: `5.*fail` matched
        # `Criterion 108005 (Failure path)` on 2026-09-27.
        refute response_text(conversation) =~ ~r/the same feedback has repeated/i

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[completed]"
        refute response_text(tasks) =~ "[active]"
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

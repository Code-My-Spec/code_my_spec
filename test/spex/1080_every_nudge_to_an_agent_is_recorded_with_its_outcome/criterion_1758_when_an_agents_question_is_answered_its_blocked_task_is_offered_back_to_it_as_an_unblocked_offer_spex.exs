defmodule CodeMySpecSpex.Story1080.Criterion1758Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1758 — When an agent's question is answered, its blocked task is
  offered back to it as an unblocked offer, after any turn it has in flight,
  and never as a second active task.

  Product asks about a design, takes triage while it waits, and is answered
  mid-triage.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers, only: [offers: 3, listing: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An answer reaching a busy agent is not a second active task", criterion: 1758 do
    scenario "product is answered about one design while it works another" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "product asked about one design, then took up another and ended its turn",
             context do
        context = asked_about_design(context)
        :ok = Fixtures.start_turn(context.scope, context.product_id)

        other =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Receipt formatting",
            description: "A story still to be designed",
            acceptance_criteria: ["Receipts are readable"]
          )

        {:reply, started, _} = start_design(context, other)
        refute started.isError, response_text(started)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.product_id)
        :ok = Fixtures.end_turn(context.scope, context.product_id, [])
        flush_transport()
        {:ok, Map.put(context, :other_task, extract_task_id!(started))}
      end

      when_ "the user answers the first question", context do
        :ok = Fixtures.answer_question(context.scope, context.question, "Shopper")
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "product is offered nothing yet", context do
        product_id = context.product_id
        refute_receive {:work_turn_requested, ^product_id, _ref, _prompt}, 1_000
        assert offers(context, product_id, %{kind: "unblocked"}) == [], listing(context)
        {:ok, context}
      end

      then_ "and the answered design cannot be resumed beside the active one", context do
        {:reply, refused, _} = start_design(context)
        assert refused.isError
        assert response_text(refused) =~ "beside your active task"
        assert active(context) == [context.other_task]
        {:ok, context}
      end
    end
  end

  spex "The answered task is offered back once the agent is free", criterion: 1758 do
    scenario "product finishes triage after its answer arrived" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "product, mid-triage, was answered about its design", context do
        context = asked_then_triaging(context)
        :ok = Fixtures.start_turn(context.scope, context.product_id)
        :ok = Fixtures.answer_question(context.scope, context.question, "Shopper")
        flush_transport()
        {:ok, context}
      end

      when_ "it triages the issue, finishes the task, and ends its turn", context do
        {:reply, dismissed, _} =
          DismissIssue.execute(
            %{issue_id: context.issue, reason: "Duplicate of a known receipts bug"},
            context.product_frame
          )

        refute dismissed.isError, response_text(dismissed)

        {:reply, evaluated, _} =
          EvaluateTask.execute(%{task_id: context.triage_task}, context.product_frame)

        refute evaluated.isError, response_text(evaluated)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.product_id)
        :ok = Fixtures.end_turn(context.scope, context.product_id, [])
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "it is offered the design back, recorded as an unblocked offer", context do
        product_id = context.product_id
        assert_receive {:work_turn_requested, ^product_id, _ref, prompt}, 2_000
        assert prompt =~ "resume task #{context.design_task}"

        assert [%{status: "open"}] =
                 offers(context, product_id, %{kind: "unblocked"}),
               listing(context)

        {:ok, context}
      end

      then_ "and resuming it makes it the one active task", context do
        {:reply, resumed, _} = start_design(context)
        refute resumed.isError, response_text(resumed)
        assert active(context) == [context.design_task]
        {:ok, context}
      end
    end
  end

  # Product designs a story, asks the user about it (blocking that task), and
  # ends the turn.
  defp asked_about_design(context) do
    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "Refund policy",
        description: "A story whose persona is unclear",
        acceptance_criteria: ["The stated behavior is specified"]
      )

    product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
    context = Map.merge(context, %{product_id: product.id, product_frame: frame, story: story})

    :ok = Fixtures.start_turn(context.scope, product.id)
    {:reply, started, _} = start_design(context)
    refute started.isError, response_text(started)
    design_task = extract_task_id!(started)

    {:reply, asked, _} =
      AskUserQuestion.execute(
        %{
          task_id: design_task,
          questions: [
            %{
              question: "Who is the primary persona for refunds?",
              options: [%{label: "Shopper"}, %{label: "Clerk"}]
            }
          ]
        },
        frame
      )

    refute asked.isError, response_text(asked)
    :ok = Fixtures.end_turn(context.scope, product.id, [])

    {:reply, tasks, _} = ListTasks.execute(%{}, frame)
    [_, question] = Regex.run(~r/blocked on question `([0-9a-f-]+)`/, response_text(tasks))
    Map.merge(context, %{design_task: design_task, question: question})
  end

  # Then, in its next turn, takes triage of a filed issue.
  defp asked_then_triaging(context) do
    context = asked_about_design(context)
    frame = context.product_frame

    {:reply, filed, _} =
      CreateIssue.execute(
        %{title: "Receipts print the wrong total", description: "Seen in QA", severity: "medium"},
        %Frame{assigns: %{current_scope: context.scope}}
      )

    refute filed.isError, response_text(filed)
    [issue | _] = Regex.run(~r/[0-9a-f]{8}-[0-9a-f-]{27}/, response_text(filed))

    {:reply, triage, _} =
      StartTask.execute(
        %{
          requirement_name: "issues_triaged",
          entity_type: "project",
          entity_id: to_string(context.project.id)
        },
        frame
      )

    refute triage.isError, response_text(triage)
    flush_transport()

    Map.merge(context, %{issue: issue, triage_task: extract_task_id!(triage)})
  end

  defp start_design(context, story \\ nil) do
    StartTask.execute(
      %{
        requirement_name: "three_amigos_complete",
        entity_type: "story",
        entity_id: to_string((story || context.story).number)
      },
      context.product_frame
    )
  end

  defp active(context) do
    {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.product_frame)

    ~r/`([0-9a-f-]{36})`/
    |> Regex.scan(response_text(tasks), capture: :all_but_first)
    |> List.flatten()
  end

  defp flush_transport do
    receive do
      {:work_turn_requested, _id, _ref, _prompt} -> flush_transport()
      {:agent_dispatch, _id, _ref, _message} -> flush_transport()
      {:agent_message, _id, _message} -> flush_transport()
    after
      0 -> :ok
    end
  end
end

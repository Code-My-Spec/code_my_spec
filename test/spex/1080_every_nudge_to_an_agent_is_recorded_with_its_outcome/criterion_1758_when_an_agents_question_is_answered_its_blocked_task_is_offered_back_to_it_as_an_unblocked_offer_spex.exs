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

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.OfferHelpers, only: [offers: 3, listing: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
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

        started = start_design(context, other)
        assert match?({:ok, _}, started), response_text(started)
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
        refused = start_design(context)
        assert match?({:error, _}, refused)
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
        dismissed =
          ToolLibrary.run(
            "dismiss_issue",
            %{issue_id: context.issue, reason: "Duplicate of a known receipts bug"},
            Map.put(
              context.product_frame.assigns,
              :scope,
              context.product_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, dismissed), response_text(dismissed)

        evaluated =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.triage_task},
            Map.put(
              context.product_frame.assigns,
              :scope,
              context.product_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, evaluated), response_text(evaluated)
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
        resumed = start_design(context)
        assert match?({:ok, _}, resumed), response_text(resumed)
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
    started = start_design(context)
    assert match?({:ok, _}, started), response_text(started)
    design_task = extract_task_id!(started)

    asked =
      ToolLibrary.run(
        "ask_user_question",
        %{
          task_id: design_task,
          questions: [
            %{
              question: "Who is the primary persona for refunds?",
              options: [%{label: "Shopper"}, %{label: "Clerk"}]
            }
          ]
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, asked), response_text(asked)
    :ok = Fixtures.end_turn(context.scope, product.id, [])

    tasks =
      ToolLibrary.run(
        "list_tasks",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    [_, question] = Regex.run(~r/blocked on question `([0-9a-f-]+)`/, response_text(tasks))
    Map.merge(context, %{design_task: design_task, question: question})
  end

  # Then, in its next turn, takes triage of a filed issue.
  defp asked_then_triaging(context) do
    context = asked_about_design(context)
    frame = context.product_frame

    filed =
      ToolLibrary.run(
        "create_issue",
        %{title: "Receipts print the wrong total", description: "Seen in QA", severity: "medium"},
        %{scope: context.scope}
      )

    assert match?({:ok, _}, filed), response_text(filed)
    [issue | _] = Regex.run(~r/[0-9a-f]{8}-[0-9a-f-]{27}/, response_text(filed))

    triage =
      ToolLibrary.run(
        "start_task",
        %{
          requirement_name: "issues_triaged",
          entity_type: "project",
          entity_id: to_string(context.project.id)
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, triage), response_text(triage)
    flush_transport()

    Map.merge(context, %{issue: issue, triage_task: extract_task_id!(triage)})
  end

  defp start_design(context, story \\ nil) do
    ToolLibrary.run(
      "start_task",
      %{
        requirement_name: "three_amigos_complete",
        entity_type: "story",
        entity_id: to_string((story || context.story).number)
      },
      Map.put(
        context.product_frame.assigns,
        :scope,
        context.product_frame.assigns[:current_scope]
      )
    )
  end

  defp active(context) do
    tasks =
      ToolLibrary.run(
        "list_tasks",
        %{status: "active"},
        Map.put(
          context.product_frame.assigns,
          :scope,
          context.product_frame.assigns[:current_scope]
        )
      )

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

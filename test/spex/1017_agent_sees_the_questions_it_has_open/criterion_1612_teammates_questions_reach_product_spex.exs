defmodule CodeMySpecSpex.Story1017.Criterion1612Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 1612 — Teammates' questions reach product.

  A teammate's question about the criteria is product's to answer, and it
  reaches product while product has an open question of its own. That its own
  question blocks only the task it was asked about is criterion 1757.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Teammates' questions reach product", criterion: 1612 do
    scenario "Product has asked the user something and still hears a teammate" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous product agent with design work, and a coder on a story", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story whose criterion is unclear",
            acceptance_criteria: ["The stated behavior is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        owed =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Receipt formatting",
            description: "A story still to be designed",
            acceptance_criteria: ["Receipts are readable"]
          )

        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = put_to_work(context)
        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            coder_frame
          )

        refute started.isError, response_text(started)

        {:ok,
         Map.merge(context, %{
           product: product,
           product_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}},
           coder_frame: coder_frame,
           coder_task: extract_task_id!(started),
           owed: owed
         })}
      end

      given_ "product took a turn, asked the user a question in it, and the turn ended",
             context do
        # Its offered turn begins, as the harness reports it; the question is
        # asked inside it.
        :ok = Fixtures.start_turn(context.scope, context.product.id)

        {:reply, designing, _} =
          StartTask.execute(
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(context.owed.number)
            },
            context.product_frame
          )

        refute designing.isError, response_text(designing)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Who is the primary persona for refunds?",
                  options: [%{label: "Shopper"}, %{label: "Clerk"}]
                }
              ]
            },
            context.product_frame
          )

        refute asked.isError, response_text(asked)
        # Its turn ends with the question still open.
        :ok = Fixtures.end_turn(context.scope, context.product.id, [])
        flush_transport()
        {:ok, context}
      end

      when_ "the coder asks product about a criterion", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.coder_task,
              about: "criteria",
              questions: [
                %{question: "Does criterion 944 still mean a full refund?", options: []}
              ]
            },
            context.coder_frame
          )

        refute asked.isError, response_text(asked)
        {:ok, context}
      end

      then_ "that question still reaches product", context do
        product_id = context.product.id

        assert_receive {:work_turn_requested, ^product_id, _ref, prompt}, 2_000
        assert prompt =~ "answer_notification"
        {:ok, context}
      end
    end
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

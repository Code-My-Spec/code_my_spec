defmodule CodeMySpecSpex.Story1080.Criterion1757Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1757 — Product's own pending question blocks only the task it was
  asked about; product is offered other eligible work, such as triage, while it
  waits.

  1a02e162: product escalated a design question and then sat ~50 minutes beside
  untriaged QA issues, offered nothing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
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

  spex "Product's question blocks only its task", criterion: 1757 do
    scenario "product waits on the user about a design while an issue needs triage" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous product agent designing a story", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story whose persona is unclear",
            acceptance_criteria: ["The stated behavior is specified"]
          )

        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
        :ok = Fixtures.start_turn(context.scope, product.id)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            frame
          )

        refute started.isError, response_text(started)

        {:ok,
         Map.merge(context, %{
           product_id: product.id,
           product_frame: frame,
           design_task: extract_task_id!(started)
         })}
      end

      given_ "product asked the user a question about that design and ended its turn",
             context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.design_task,
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
        :ok = Fixtures.end_turn(context.scope, context.product_id, [])
        flush_transport()
        {:ok, context}
      end

      when_ "an issue is filed that needs triage", context do
        {:reply, filed, _} =
          CreateIssue.execute(
            %{
              title: "Receipts print the wrong total",
              description: "Seen twice in QA",
              severity: "medium"
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        refute filed.isError, response_text(filed)
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "product is offered a turn for it", context do
        product_id = context.product_id
        assert_receive {:work_turn_requested, ^product_id, _ref, _prompt}, 2_000
        {:ok, context}
      end

      then_ "and is offered triage, which it can start while its design waits", context do
        {:reply, next, _} = GetNextRequirement.execute(%{}, context.product_frame)
        refute next.isError, response_text(next)
        assert response_text(next) =~ "issues_triaged", response_text(next)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "issues_triaged",
              entity_type: "project",
              entity_id: to_string(context.project.id)
            },
            context.product_frame
          )

        refute started.isError, response_text(started)

        {:reply, tasks, _} = ListTasks.execute(%{}, context.product_frame)
        assert response_text(tasks) =~ ~r/\[blocked\][^\n]*#{context.design_task}/
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

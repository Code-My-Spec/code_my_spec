defmodule CodeMySpecSpex.Story1080.Criterion1761Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1761 — An agent holding only blocked tasks, idle beside claimable
  work for its role, is reported stalled in list_agent_work; a task-less pending
  tap-out still holds it and is not a stall.

  A blocked task holds only itself (1757), so an agent with nothing else in hand
  and work waiting is stuck, not waiting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
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

  spex "A blocked-only agent beside work is reported stalled", criterion: 1761 do
    scenario "product waits on a question and never takes the triage it is offered" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous product whose only task is blocked on its question", context do
        :ok = Fixtures.start_turn(context.scope, product(context).id)
        {:ok, context |> asked_about_design() |> end_turn()}
      end

      when_ "an issue needing triage is filed and product takes no turn", context do
        {:ok, file_issue(context)}
      end

      then_ "list_agent_work reports product stalled, its blocked task still shown", context do
        line = product_line(context)
        assert line =~ "three_amigos_complete", line
        assert line =~ "STALLED: only blocked work in hand", line
        {:ok, context}
      end
    end
  end

  spex "A task-less tap-out is not a stall", criterion: 1761 do
    scenario "product has asked to stop altogether" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous product, its task blocked on a question, that has asked to stop",
             context do
        :ok = Fixtures.start_turn(context.scope, product(context).id)
        context = asked_about_design(context)

        {:reply, tapped, _} =
          TapOut.execute(%{reason: "Nothing more I can design until answered"}, context.frame)

        refute tapped.isError, response_text(tapped)
        {:ok, end_turn(context)}
      end

      when_ "an issue needing triage is filed", context do
        {:ok, file_issue(context)}
      end

      then_ "list_agent_work does not report product stalled", context do
        line = product_line(context)
        assert line =~ "three_amigos_complete", line
        refute line =~ "STALLED", line
        {:ok, context}
      end
    end
  end

  defp product(context),
    do: Fixtures.running_agent(context.scope, role: "product", continuous: true)

  # Product starts designing a story and asks the user about it, blocking that
  # task. Expects the product agent to be the scope's only one.
  defp asked_about_design(context) do
    [product] = CodeMySpec.Agents.list_agents(context.scope)
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}

    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "Refund policy",
        description: "A story whose persona is unclear",
        acceptance_criteria: ["The stated behavior is specified"]
      )

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

    {:reply, asked, _} =
      AskUserQuestion.execute(
        %{
          task_id: extract_task_id!(started),
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
    Map.merge(context, %{product_id: product.id, frame: frame})
  end

  defp end_turn(context) do
    :ok = Fixtures.end_turn(context.scope, context.product_id, [])
    context
  end

  defp file_issue(context) do
    {:reply, filed, _} =
      CreateIssue.execute(
        %{title: "Receipts print the wrong total", description: "Seen in QA", severity: "medium"},
        %Frame{assigns: %{current_scope: context.scope}}
      )

    refute filed.isError, response_text(filed)
    context
  end

  # The product's entry in list_agent_work, from its id to the next agent's.
  defp product_line(context) do
    {:reply, work, _} =
      ListAgentWork.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

    refute work.isError, response_text(work)
    text = response_text(work)
    [_, entry] = String.split(text, context.product_id, parts: 2)
    entry
  end
end

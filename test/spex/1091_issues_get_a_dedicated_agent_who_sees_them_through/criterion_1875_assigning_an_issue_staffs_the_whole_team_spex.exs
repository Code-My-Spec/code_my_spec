defmodule CodeMySpecSpex.Story1091.Criterion1875Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1875 — Assigning an issue staffs the whole team.

  Product clarified that completing the coder's issue task submits the fix
  for QA without resolving the issue. This scenario drives that task handoff
  through MCP. Assignment and issue-scoped work are required new behavior,
  so these calls deliberately remain red until the story is implemented.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An assigned issue is carried from coding to QA by the same team", criterion: 1875 do
    scenario "both agents are bound and the fix is handed to QA after submission" do
      given_ "an unassigned working copy with a coder, QA agent, and accepted issue", context do
        context = context |> Slice.main_copy() |> Slice.staff() |> Slice.git_backed()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        created =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "A notification is missing from the agent's inbox",
              description: "The assigned team must restore delivery and have QA verify it.",
              severity: "high",
              scope: "framework"
            },
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = created
        issue_id = extract_issue_id!(created)

        accepted =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: issue_id},
            Map.put(main_frame.assigns, :scope, main_frame.assigns[:current_scope])
          )

        {:ok, _} = accepted

        {:ok,
         Map.merge(context, %{
           issue_id: issue_id,
           main_frame: main_frame,
           coder_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}},
           qa_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}
         })}
      end

      when_ "main assigns the issue to the team's copy", context do
        response =
          ToolLibrary.run(
            "assign_issue_to_working_copy",
            %{issue_id: context.issue_id, working_copy_id: context.scope.active_working_copy_id},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :assignment_response, response)}
      end

      then_ "both teammates show the issue as their assignment", context do
        assert match?({:ok, _}, context.assignment_response),
               response_text(context.assignment_response)

        response =
          ToolLibrary.run(
            "list_agent_work",
            %{},
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The listing must include teammate #{agent.id}"
          assert entry =~ context.scope.active_working_copy_id
          assert entry =~ context.issue_id
        end

        {:ok, context}
      end

      then_ "the coder is offered the issue's fix", context do
        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns.current_scope
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        offered = response_text(response)
        assert offered =~ "entity_type=`issue`"
        assert offered =~ "entity_id=`#{context.issue_id}`"
        [_, requirement_name] = Regex.run(~r/requirement_name=`([^`]+)`/, offered)

        {:ok, Map.put(context, :fix_requirement, requirement_name)}
      end

      when_ "the coder claims the offered fix", context do
        response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: context.fix_requirement,
              entity_type: "issue",
              entity_id: context.issue_id
            },
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :start_response, response)}
      end

      then_ "the coder receives a task for the fix", context do
        assert match?({:ok, _}, context.start_response), response_text(context.start_response)
        {:ok, Map.put(context, :fix_task_id, extract_task_id!(context.start_response))}
      end

      when_ "the coder submits the fix by completing its task", context do
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.fix_task_id},
            Map.put(
              context.coder_frame.assigns,
              :scope,
              context.coder_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :completion_response, response)}
      end

      then_ "QA is offered testing for the same issue", context do
        assert match?({:ok, _}, context.completion_response),
               response_text(context.completion_response)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)
        offered = response_text(response)

        assert offered =~ "entity_type=`issue`"
        assert offered =~ "entity_id=`#{context.issue_id}`"
        assert offered =~ "requirement_name=`qa_complete`"

        {:ok, context}
      end
    end
  end
end

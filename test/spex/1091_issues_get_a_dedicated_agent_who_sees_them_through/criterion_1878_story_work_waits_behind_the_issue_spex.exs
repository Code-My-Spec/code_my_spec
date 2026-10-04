defmodule CodeMySpecSpex.Story1091.Criterion1878Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1878 — Story work waits behind the issue.

  The existing story fixtures establish an actionable implementation task.
  Its availability is checked through the coder's tool before main assigns
  the issue, so an empty story queue cannot make the priority check pass.
  Assignment uses the same required MCP surface as criterion 1876; that
  surface may remain unimplemented while this acceptance spec is red.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An issue-bound coder is offered the issue ahead of ready story work", criterion: 1878 do
    scenario "ready story implementation waits while the team fixes its assigned issue" do
      given_ "a team has ready story work and is then assigned an accepted issue", context do
        context = context |> Slice.main_copy() |> Slice.base() |> Slice.child()
        coder = Enum.find(context.team, &(&1.role == :coding))

        coder_frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: coder.id}
        }

        {:reply, ready, _frame} = GetNextRequirement.execute(%{}, coder_frame)
        false = ready.isError
        ready_text = response_text(ready)
        true = ready_text =~ "implementation_file"
        true = ready_text =~ "entity_type=`component`"
        [_, story_component_id] = Regex.run(~r/entity_id=`([^`]+)`/, ready_text)

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        {:reply, created, _frame} =
          CreateIssue.execute(
            %{
              title: "The harness loses a delivered notification",
              description: "An agent never receives the notification sent to its session.",
              severity: "high",
              scope: "framework"
            },
            main_frame
          )

        false = created.isError
        issue_id = extract_issue_id!(created)
        {:reply, accepted, _frame} = AcceptIssue.execute(%{issue_id: issue_id}, main_frame)
        false = accepted.isError

        {:reply, assigned, _frame} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: issue_id, working_copy_id: context.scope.active_working_copy_id},
            main_frame
          )

        false = assigned.isError

        {:ok,
         Map.merge(context, %{
           issue_id: issue_id,
           coder_frame: coder_frame,
           story_component_id: story_component_id
         })}
      end

      when_ "the coder asks for its next work", context do
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, context.coder_frame)
        {:ok, Map.put(context, :work_response, response)}
      end

      then_ "the offer names the assigned issue and excludes the ready story work", context do
        refute context.work_response.isError, response_text(context.work_response)
        offered_work = response_text(context.work_response)

        assert offered_work =~ "entity_type=`issue`"
        assert offered_work =~ "entity_id=`#{context.issue_id}`"
        refute offered_work =~ "entity_type=`story`"
        refute offered_work =~ "entity_type=`component`"
        refute offered_work =~ "entity_id=`#{context.story_component_id}`"

        {:ok, context}
      end
    end
  end
end

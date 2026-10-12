defmodule CodeMySpecSpex.Story1091.Criterion2018Spex do
  @moduledoc "A completed fix hands the issue to QA without permitting a duplicate coding task."
  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A completed fix is offered to QA alone", criterion: 2018 do
    scenario "The coder cannot claim the submitted fix again" do
      given_ "a coder has claimed an accepted issue assigned to its team", context do
        context = context |> Slice.main_copy() |> Slice.staff() |> Slice.git_backed()
        coder = Enum.find(context.team, &(&1.role == :coding))
        qa = Enum.find(context.team, &(&1.role == :qa))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}
        qa_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}

        {:reply, created, _} =
          CreateIssue.execute(
            %{
              title: "A notification is lost",
              description: "Restore notification delivery.",
              severity: "high",
              scope: "framework"
            },
            main_frame
          )

        false = created.isError
        issue_id = extract_issue_id!(created)
        {:reply, accepted, _} = AcceptIssue.execute(%{issue_id: issue_id}, main_frame)
        false = accepted.isError

        {:reply, assigned, _} =
          AssignIssueToWorkingCopy.execute(
            %{issue_id: issue_id, working_copy_id: context.scope.active_working_copy_id},
            main_frame
          )

        false = assigned.isError
        {:reply, offered, _} = GetNextRequirement.execute(%{}, coder_frame)
        false = offered.isError
        true = response_text(offered) =~ "requirement_name=`fix_issue`"
        params = %{requirement_name: "fix_issue", entity_type: "issue", entity_id: issue_id}
        {:reply, started, _} = StartTask.execute(params, coder_frame)
        false = started.isError

        {:ok,
         Map.merge(context, %{
           coder_frame: coder_frame,
           qa_frame: qa_frame,
           params: params,
           task_id: extract_task_id!(started),
           issue_id: issue_id
         })}
      end

      when_ "the coder evaluates its fix successfully", context do
        Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

        {:reply, evaluated, _} =
          EvaluateTask.execute(%{task_id: context.task_id}, context.coder_frame)

        refute evaluated.isError, response_text(evaluated)
        {:ok, context}
      end

      then_ "the coder has no fix offer and a repeated claim is refused", context do
        {:reply, offered, _} = GetNextRequirement.execute(%{}, context.coder_frame)
        refute offered.isError, response_text(offered)
        refute response_text(offered) =~ "requirement_name=`fix_issue`"
        {:reply, duplicate, _} = StartTask.execute(context.params, context.coder_frame)
        assert duplicate.isError, response_text(duplicate)
        {:ok, context}
      end

      then_ "QA is offered and can claim the submitted issue", context do
        {:reply, offered, _} = GetNextRequirement.execute(%{}, context.qa_frame)
        refute offered.isError, response_text(offered)
        assert response_text(offered) =~ "requirement_name=`qa_complete`"
        assert response_text(offered) =~ "entity_id=`#{context.issue_id}`"

        {:reply, started, _} =
          StartTask.execute(
            %{requirement_name: "qa_complete", entity_type: "issue", entity_id: context.issue_id},
            context.qa_frame
          )

        refute started.isError, response_text(started)
        {:ok, context}
      end
    end
  end
end

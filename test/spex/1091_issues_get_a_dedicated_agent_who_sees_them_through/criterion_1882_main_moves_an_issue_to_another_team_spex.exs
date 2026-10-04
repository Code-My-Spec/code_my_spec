defmodule CodeMySpecSpex.Story1091.Criterion1882Spex do
  @moduledoc """
  Story 1091 — Criterion 1882: Main moves an issue to another team.

  The proposed AssignIssueToWorkingCopy surface accepts a reason when moving
  an assigned issue. The open task follows the issue to the new coder;
  list_tasks and list_agent_work expose the resulting ownership.
  """
  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{AcceptIssue, AssignIssueToWorkingCopy, CreateIssue}
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.{ListTasks, StartTask}
  alias CodeMySpecSpex.{Fixtures, OfferHelpers}
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main reassigns an issue and its open coding task to another team", criterion: 1882 do
    scenario "Team B takes over the issue while team A becomes free" do
      given_ "team A owns an issue with an open coding task and team B is idle", context do
        context = context |> Slice.main_copy() |> Slice.staff()
        scope_b = Fixtures.live_agent_scope(context.scope, label: "Team B checkout")
        context_b = Slice.staff(%{scope: scope_b})
        coder_a = Enum.find(context.team, &(&1.role == :coding))
        coder_b = Enum.find(context_b.team, &(&1.role == :coding))

        main_frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        coder_a_frame = OfferHelpers.agent_frame(context, coder_a.id)
        coder_b_frame = OfferHelpers.agent_frame(context_b, coder_b.id)

        {:reply, created, _} =
          CreateIssue.execute(
            %{
              title: "Restore issue search results",
              description: "Accepted issues must appear in search.",
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
            %{
              issue_id: issue_id,
              working_copy_id: context.scope.active_working_copy_id
            },
            main_frame
          )

        false = assigned.isError

        task_args = OfferHelpers.next_task(context, coder_a.id)
        true = task_args.entity_type == "issue"
        true = task_args.entity_id == issue_id
        {:reply, started, _} = StartTask.execute(task_args, coder_a_frame)
        false = started.isError
        task_id = extract_task_id!(started)
        {:reply, held, _} = ListTasks.execute(%{status: "active"}, coder_a_frame)
        false = held.isError
        true = response_text(held) =~ task_id
        {:reply, idle, _} = ListTasks.execute(%{status: "active"}, coder_b_frame)
        false = idle.isError
        true = response_text(idle) == "No tasks."

        {:ok,
         Map.merge(context, %{
           scope_b: scope_b,
           team_b: context_b.team,
           main_frame: main_frame,
           coder_a_frame: coder_a_frame,
           coder_b_frame: coder_b_frame,
           issue_id: issue_id,
           task_id: task_id,
           task_args: task_args
         })}
      end

      when_ "main moves the issue to team B with a reason", context do
        {:reply, response, _} =
          AssignIssueToWorkingCopy.execute(
            %{
              issue_id: context.issue_id,
              working_copy_id: context.scope_b.active_working_copy_id,
              reason:
                "Team B has capacity to finish this fix while team A handles another assignment."
            },
            context.main_frame
          )

        {:ok, Map.put(context, :reassignment, response)}
      end

      then_ "both members of team B are bound to the issue and team A is free", context do
        refute context.reassignment.isError, response_text(context.reassignment)
        {:reply, response, _} = ListAgentWork.execute(%{}, context.main_frame)
        refute response.isError, response_text(response)
        entries = response |> response_text() |> String.split("Agent: ")

        for agent <- context.team_b do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry
          assert entry =~ context.scope_b.active_working_copy_id
          assert entry =~ context.issue_id
          refute entry =~ "Assignment: none"
        end

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry
          assert entry =~ context.scope.active_working_copy_id
          assert entry =~ "Assignment: none"
        end

        {:ok, context}
      end

      then_ "the original open task belongs to team B's coder and no longer to team A's coder",
            context do
        {:reply, old_tasks, _} = ListTasks.execute(%{status: "active"}, context.coder_a_frame)
        refute old_tasks.isError, response_text(old_tasks)
        refute response_text(old_tasks) =~ context.task_id

        {:reply, new_tasks, _} = ListTasks.execute(%{status: "active"}, context.coder_b_frame)
        refute new_tasks.isError, response_text(new_tasks)
        rows = String.split(response_text(new_tasks), "\n")
        matching = Enum.filter(rows, &String.contains?(&1, "`#{context.task_id}`"))
        assert [row] = matching
        assert row =~ "[active]"
        assert row =~ "**#{context.task_args.requirement_name}**"
        {:ok, context}
      end
    end
  end
end

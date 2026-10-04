defmodule CodeMySpecSpex.Story1091.Criterion1877Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1877 — The user assigns from the issue page.

  The assignment control is not implemented yet. This spec declares its
  surface: an issue-assignment form with a working_copy_id selector.
  Submitting it must bind both teammates, observable in list_agent_work.
  Existing fixture helpers establish the idle team; the assignment itself
  is produced only by the user's LiveView interaction.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The user assigns an issue to a working copy's whole team", criterion: 1877 do
    scenario "an accepted issue is assigned from its page" do
      given_ "an accepted issue and an unassigned copy with a coder and QA agent", context do
        context = context |> Slice.main_copy() |> Slice.staff()

        issue =
          Fixtures.issue_fixture(context.scope, %{title: "Fix the missing issue assignment"})

        {:ok, issue_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/issues/#{issue.id}")

        issue_live |> element("button[phx-click='accept']") |> render_click()

        {:ok, Map.merge(context, %{issue: issue, issue_live: issue_live})}
      end

      when_ "the user selects the team's working copy and submits the assignment", context do
        context.issue_live
        |> form("[data-test='issue-assignment-form']", %{
          "working_copy_id" => context.scope.active_working_copy_id
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "both the coder and QA agent are shown bound to this issue", context do
        frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.main.id}
        }

        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)
        refute response.isError, response_text(response)
        listing = response_text(response)
        entries = String.split(listing, "Agent: ")

        for agent <- context.team do
          entry = Enum.find(entries, &String.starts_with?(&1, agent.id <> "\n"))
          assert entry, "The team member #{agent.id} is missing from the work listing"
          assert entry =~ context.scope.active_working_copy_id

          assert entry =~ context.issue.id,
                 "The team member #{agent.id} is not shown bound to issue #{context.issue.id}: #{entry}"
        end

        {:ok, context}
      end
    end
  end
end

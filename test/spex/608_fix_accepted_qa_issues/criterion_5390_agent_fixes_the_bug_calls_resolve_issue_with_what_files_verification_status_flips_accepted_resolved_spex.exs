defmodule CodeMySpecSpex.Story608.Criterion5390Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5390 — Agent fixes the bug, calls resolve_issue with
  what / files / verification, status flips accepted → resolved.

  Rule 3: every fix is documented via the `resolve_issue` MCP tool.
  The resolution body must describe what was fixed, which files
  changed, and how the fix was verified.

  Surface: `resolve_issue` MCP tool. State is observed back through
  `list_issues` (status filter `accepted`) — no DB reads in `then_`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.{ListIssues, ResolveIssue}

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "resolve_issue documents the fix and flips the status" do
    scenario "Agent fixes the bug, calls resolve_issue with what / files / verification, status flips accepted → resolved" do
      given_ "an accepted issue exists describing a 500 on /app/projects/new",
             context do
        issue =
          Fixtures.issue_fixture(context.scope, %{
            severity: :high,
            status: :accepted,
            title: "500 on /app/projects/new",
            description: "Form submission raises FunctionClauseError"
          })

        {:ok, Map.put(context, :issue, issue)}
      end

      when_ "the agent calls resolve_issue with id and a what/files/verification resolution",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        resolution = """
        Fixed: function clause caught nil owner_id before changeset.
        Files: lib/code_my_spec_web/controllers/projects_controller.ex
        Verified: mix test passes; manual repro on /app/projects/new returns 200.
        """

        {:reply, response, _frame} =
          ResolveIssue.execute(
            %{issue_id: context.issue.id, resolution: resolution},
            frame
          )

        {:ok, Map.put(context, :resolve_response, response)}
      end

      then_ "the resolve_issue response confirms the issue was resolved",
            context do
        body = response_text(context.resolve_response)

        assert body =~ ~r/resolved/i,
               "expected response to confirm resolution, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the issue no longer appears in the accepted list", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListIssues.execute(%{status: "accepted"}, frame)

        body = response_text(list_response)

        refute body =~ context.issue.id,
               "expected accepted-status list to exclude resolved issue #{context.issue.id}, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end

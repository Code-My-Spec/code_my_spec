defmodule CodeMySpecSpex.Story608.Criterion5392Spex do
  @moduledoc """
  Story 608 — Fix accepted QA issues
  Criterion 5392 — mix test passes clean after fixes, evaluate marks
  the task done.

  Rule 4 (happy path): once every accepted issue has been resolved
  and tests are clean, evaluate marks the fix-issues task done and
  the requirement graph advances past `issues_resolved`.

  Surface: `start_task` for `issues_resolved`, then the stop-hook
  drives evaluate. The "no unresolved medium+ issues" precondition
  is established by leaving every issue at :resolved status (the
  output state of a clean fix loop) — the spec then checks that the
  graph advances, which is the agent-visible signal that the work
  is accepted.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Clean state after fixes evaluates as valid" do
    scenario "mix test passes clean after fixes, evaluate marks the task done" do
      given_ "the project has one issue, already resolved (no unresolved medium+ remain)",
             context do
        # Output state of a successful fix loop: every accepted issue
        # has been transitioned to :resolved with a resolution attached.
        Fixtures.issue_fixture(context.scope, %{
          severity: :high,
          status: :resolved,
          resolution: "Fixed in lib/foo.ex; mix test passes.",
          title: "Already-resolved issue"
        })

        {:ok, context}
      end

      given_ :fix_issues_task_started

      when_ "the agent fires the stop hook on the active fix-issues task",
            context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "the graph advances past issues_resolved", context do
        # When the stop hook completes the task, the next
        # get_next_requirement call must surface a different requirement
        # (or an all-satisfied marker) — never issues_resolved again.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        body = response_text(response)

        refute body =~ "issues_resolved",
               "expected the graph to advance past issues_resolved once all accepted issues are resolved, got: #{body}"

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

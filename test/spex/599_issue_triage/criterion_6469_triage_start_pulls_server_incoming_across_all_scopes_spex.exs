defmodule CodeMySpecSpex.Story599.Criterion6469Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 6469 — Triage start pulls server-side incoming issues
  across all scopes into the local view.

  Asserts that `start_task` for `issues_triaged`:
  - synchronously fetches incoming issues from the configured remote
    across every scope (:app, :qa, :docs, :framework),
  - upserts them into the local DB so `list_issues` returns them,
  - returns a prompt that does NOT enumerate issues but DOES direct
    the agent to discover them via `list_issues` / `get_issue`.

  RED until 599's pull-on-start machinery and the RemoteClientStub
  seeding helpers land together.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Starting a triage task pulls all incoming server-side issues across every scope into the local view, and the agent discovers them via list_issues and get_issue rather than from a prompt enumeration" do
    scenario "Triage start pulls server-side incoming issues across all scopes into the local view" do
      given_ "the remote server has incoming issues at :medium+ across :app, :qa, :docs, and :framework scopes", context do
        scope = context.scope

        seeded =
          for {sc, sev, title} <- [
                {:app, :high, "Server app issue"},
                {:qa, :medium, "Server qa issue"},
                {:docs, :medium, "Server docs issue"},
                {:framework, :high, "Server framework issue"}
              ] do
            {:ok, issue} =
              Fixtures.seed_server_incoming_issue(scope, %{
                id: Ecto.UUID.generate(),
                title: title,
                severity: sev,
                scope: sc,
                description: "server-side incoming"
              })

            issue
          end

        {:ok, Map.put(context, :server_issues, seeded)}
      end

      given_ "the local DB has none of those issues yet", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = ListIssues.execute(%{status: "incoming"}, frame)
        text = response_text(response)

        for issue <- context.server_issues do
          refute text =~ issue.id,
                 "expected local list_issues to NOT yet contain server issue #{issue.id} before triage start, got: #{inspect(text)}"
        end

        {:ok, context}
      end

      given_ "a session is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the operator starts a triage task with the default threshold", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "issues_triaged",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :triage_prompt, response_text(response))}
      end

      when_ "the agent calls list_issues(status: :incoming)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = ListIssues.execute(%{status: "incoming"}, frame)
        {:ok, Map.put(context, :list_issues_text, response_text(response))}
      end

      then_ "list_issues returns every server-side incoming issue across all scopes", context do
        for issue <- context.server_issues do
          assert context.list_issues_text =~ issue.id,
                 "expected list_issues to include pulled-from-server issue #{issue.id} (scope: #{issue.scope}), got: #{inspect(context.list_issues_text)}"
        end

        {:ok, context}
      end

      then_ "the triage prompt does not enumerate any issue id", context do
        for issue <- context.server_issues do
          refute context.triage_prompt =~ issue.id,
                 "expected triage prompt to NOT enumerate issue #{issue.id} under the tool-driven model, got: #{inspect(context.triage_prompt)}"
        end

        {:ok, context}
      end

      then_ "the triage prompt directs the agent to use list_issues and get_issue", context do
        assert context.triage_prompt =~ ~r/list_issues/i,
               "expected triage prompt to mention `list_issues`, got: #{inspect(context.triage_prompt)}"

        assert context.triage_prompt =~ ~r/get_issue/i,
               "expected triage prompt to mention `get_issue`, got: #{inspect(context.triage_prompt)}"

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

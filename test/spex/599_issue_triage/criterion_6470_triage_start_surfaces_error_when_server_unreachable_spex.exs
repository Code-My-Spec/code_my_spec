defmodule CodeMySpecSpex.Story599.Criterion6470Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 6470 — Triage start surfaces a clear error when the server
  is unreachable.

  Asserts that `start_task` for `issues_triaged` fails loudly when the
  remote pull fails — no silent degradation to a local-only triage
  prompt. Local DB stays unchanged.

  RED until 599's pull-on-start machinery and the RemoteClientStub
  `simulate_unreachable/1` helper land together.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.Issues.RemoteClientStub
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Starting a triage task pulls all incoming server-side issues across every scope into the local view, and the agent discovers them via list_issues and get_issue rather than from a prompt enumeration" do
    scenario "Triage start surfaces a clear error when the server is unreachable" do
      given_ "the remote server is unreachable", context do
        :ok = RemoteClientStub.simulate_unreachable(true)
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

      when_ "the operator starts a triage task", context do
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

        {:ok, Map.put(context, :start_response_text, response_text(response))}
      end

      then_ "the response surfaces an error explaining the server cannot be reached", context do
        text = context.start_response_text

        assert text =~ ~r/(error|unreachable|cannot|fail)/i,
               "expected start_task response to surface a server-unreachable error, got: #{inspect(text)}"

        {:ok, context}
      end

      then_ "no triage prompt is built", context do
        text = context.start_response_text

        refute text =~ ~r/(triage at|medium\+|incoming issues)/i,
               "expected no triage prompt body in the error response, got: #{inspect(text)}"

        {:ok, context}
      end

      then_ "the local DB is unchanged (no new incoming issues)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = ListIssues.execute(%{status: "incoming"}, frame)
        text = response_text(response)

        assert text =~ ~r/(no issues|0 issues)/i,
               "expected no incoming issues after failed pull, got: #{inspect(text)}"

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

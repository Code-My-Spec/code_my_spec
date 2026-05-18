defmodule CodeMySpecSpex.Story709.Criterion6471Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6471 — Dispositioning a server-origin issue syncs the new
  status back to the server.

  Asserts that when an agent accepts an issue that originated on the
  server (was pulled into local via the triage-start sync), the local
  transition AND the remote update both happen — and the
  `RemoteClientStub` records the update call.

  RED until 709's sync-back wiring on accept/dismiss/resolve and the
  RemoteClientStub `update_calls_for/1` introspection helper land
  together.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dispositions on server-origin issues (accept, dismiss, resolve) sync to the server synchronously and fail loudly on transport error, while local-only issues bypass the sync entirely" do
    scenario "Dispositioning a server-origin issue syncs the new status back to the server" do
      given_ "the remote server has an incoming issue", context do
        scope = context.scope

        {:ok, issue} =
          Fixtures.seed_server_incoming_issue(scope, %{
            id: Ecto.UUID.generate(),
            title: "Server-origin issue",
            severity: :high,
            scope: :app,
            description: "filed on the server"
          })

        {:ok, Map.put(context, :issue, issue)}
      end

      given_ "the triage start pull has imported the issue into the local DB", context do
        {:ok, _} = Fixtures.sync_server_issues_to_local(context.scope)
        {:ok, context}
      end

      when_ "the agent calls accept_issue on the local copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AcceptIssue.execute(
            %{issue_id: context.issue.id, category: "bug"},
            frame
          )

        {:ok, Map.put(context, :accept_response_text, response_text(response))}
      end

      then_ "the accept response indicates success", context do
        assert context.accept_response_text =~ ~r/(accepted|success)/i,
               "expected accept_issue to indicate success, got: #{inspect(context.accept_response_text)}"

        {:ok, context}
      end

      then_ "get_issue shows the local issue status is :accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = GetIssue.execute(%{issue_id: context.issue.id}, frame)
        text = response_text(response)

        assert text =~ ~r/status[:*\s]+accepted/i,
               "expected local issue #{context.issue.id} to show :accepted, got: #{inspect(text)}"

        {:ok, context}
      end

      then_ "the remote client received the status update for this issue id", context do
        calls = Fixtures.server_update_calls_for(context.issue.id)

        assert length(calls) >= 1,
               "expected the server to have recorded at least one update for #{context.issue.id}, got: #{inspect(calls)}"

        assert Enum.any?(calls, fn call ->
                 call[:status] in ["accepted", :accepted] or
                   call["status"] in ["accepted", :accepted]
               end),
               "expected one of the recorded remote updates to set status accepted, got: #{inspect(calls)}"

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

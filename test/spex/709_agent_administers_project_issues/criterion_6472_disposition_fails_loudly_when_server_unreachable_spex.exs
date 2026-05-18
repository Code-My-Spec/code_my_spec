defmodule CodeMySpecSpex.Story709.Criterion6472Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6472 — Dispositioning a server-origin issue fails loudly
  when the server is unreachable.

  Asserts that when the sync-back fails (server unreachable), the
  local transition does NOT flip — the issue stays :incoming and the
  agent gets a clear error. No half-applied state.

  RED until 709's sync-back wiring lands with synchronous error
  propagation (not fire-and-forget like today's `resolve_issue`
  remote sync).
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.Issues.RemoteClientStub
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dispositions on server-origin issues (accept, dismiss, resolve) sync to the server synchronously and fail loudly on transport error, while local-only issues bypass the sync entirely" do
    scenario "Dispositioning a server-origin issue fails loudly when the server is unreachable" do
      given_ "the remote server has an incoming issue", context do
        scope = context.scope

        {:ok, issue} =
          RemoteClientStub.seed_incoming_issue(scope, %{
            id: Ecto.UUID.generate(),
            title: "Server-origin issue",
            severity: :high,
            scope: :app,
            description: "filed on the server"
          })

        {:ok, Map.put(context, :issue, issue)}
      end

      given_ "the triage start pull has imported the issue into the local DB", context do
        {:ok, _} = RemoteClientStub.pull_to_local(context.scope)
        {:ok, context}
      end

      given_ "the remote server becomes unreachable", context do
        :ok = RemoteClientStub.simulate_unreachable(true)
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

      then_ "the accept response surfaces a server-unreachable error", context do
        assert context.accept_response_text =~ ~r/(error|unreachable|cannot|fail)/i,
               "expected accept_issue to surface a server-unreachable error, got: #{inspect(context.accept_response_text)}"

        {:ok, context}
      end

      then_ "the local issue status remains :incoming (no half-applied state)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = GetIssue.execute(%{issue_id: context.issue.id}, frame)
        text = response_text(response)

        assert text =~ ~r/status:?\s*incoming/i,
               "expected local issue #{context.issue.id} to remain :incoming after failed sync, got: #{inspect(text)}"

        refute text =~ ~r/status:?\s*accepted/i,
               "expected local issue to NOT show :accepted after failed sync, got: #{inspect(text)}"

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

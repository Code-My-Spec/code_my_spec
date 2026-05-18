defmodule CodeMySpecSpex.Story709.Criterion6473Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6473 — Local-only issue dispositions bypass the server
  sync.

  When an issue is created locally (via `create_issue` with a non-
  framework scope) and has no server record, dispositioning it must
  flip the local status without contacting the remote. The transition
  must succeed even when the server is unreachable.

  RED until 709's sync-back wiring lands with origin-aware routing
  (server-origin → sync; local-only → bypass) and the
  RemoteClientStub `update_calls_for/1` introspection helper lands.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.Issues.RemoteClientStub
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dispositions on server-origin issues (accept, dismiss, resolve) sync to the server synchronously and fail loudly on transport error, while local-only issues bypass the sync entirely" do
    scenario "Local-only issue dispositions bypass the server sync" do
      given_ "the agent creates a local-only :app issue via create_issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Local-only app bug",
              severity: "high",
              description: "Filed locally; not on the server",
              scope: "app"
            },
            frame
          )

        text = response_text(response)
        [_, issue_id] = Regex.run(~r/ID:?\s*([0-9a-f-]{36})/i, text) || [nil, nil]

        assert is_binary(issue_id),
               "expected create_issue response to surface a UUID for the new local issue, got: #{inspect(text)}"

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      given_ "the remote server is unreachable (to prove the local path doesn't try to talk to it)", context do
        :ok = RemoteClientStub.simulate_unreachable(true)
        {:ok, context}
      end

      when_ "the agent calls accept_issue on the local-only issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AcceptIssue.execute(%{issue_id: context.issue_id, category: "bug"}, frame)

        {:ok, Map.put(context, :accept_response_text, response_text(response))}
      end

      then_ "the accept response indicates success even with the server unreachable", context do
        assert context.accept_response_text =~ ~r/(accepted|success)/i,
               "expected accept_issue on a local-only issue to succeed regardless of server reachability, got: #{inspect(context.accept_response_text)}"

        refute context.accept_response_text =~ ~r/(unreachable|cannot reach)/i,
               "expected NO server-unreachable error for a local-only disposition, got: #{inspect(context.accept_response_text)}"

        {:ok, context}
      end

      then_ "get_issue shows the local-only issue is :accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = GetIssue.execute(%{issue_id: context.issue_id}, frame)
        text = response_text(response)

        assert text =~ ~r/status:?\s*accepted/i,
               "expected local-only issue to show :accepted, got: #{inspect(text)}"

        {:ok, context}
      end

      then_ "the remote client received NO update calls for this issue id", context do
        calls = RemoteClientStub.update_calls_for(context.issue_id)

        assert calls == [],
               "expected RemoteClientStub to have received NO update calls for local-only issue #{context.issue_id}, but got: #{inspect(calls)}"

        {:ok, context}
      end

      then_ "list_issues confirms the issue is in the local DB and accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _} = ListIssues.execute(%{status: "accepted"}, frame)
        text = response_text(response)

        assert text =~ context.issue_id,
               "expected list_issues(status: accepted) to include the local-only issue #{context.issue_id}, got: #{inspect(text)}"

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

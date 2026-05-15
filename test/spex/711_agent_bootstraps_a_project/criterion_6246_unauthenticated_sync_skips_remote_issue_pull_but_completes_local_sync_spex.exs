defmodule CodeMySpecSpex.Story711.Criterion6246Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6246 — Unauthenticated sync skips remote issue pull but completes local sync.

  When the agent calls `sync_project` from a session that has no OAuth
  credentials, the response indicates the remote issue sync was skipped
  and the local file and component sync still ran to completion (the
  response carries both `Files:` and `Components:` summary lines).

  Surface: `SyncProject` MCP tool. Test scopes start with no OAuth
  credentials, which is the unauthenticated state the tool's `if
  OAuthClient.authenticated?()` branch handles.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.SyncProject

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "sync_project rebuilds the requirement graph and returns a file/component summary" do
    scenario "Unauthenticated sync skips remote issue pull but completes local sync" do
      given_ "the agent is not authenticated to the remote SaaS server", context do
        # No OAuth credentials are seeded for this scope. The
        # `OAuthClient.authenticated?/0` check inside sync_project is
        # what gates the remote pull; in test environments without a
        # stored token it returns false.
        {:ok, context}
      end

      when_ "the agent calls sync_project", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = SyncProject.execute(%{}, frame)
        {:ok, Map.put(context, :sync_response, response)}
      end

      then_ "the response text indicates the remote issue sync was skipped", context do
        body = response_text(context.sync_response)

        assert body =~ ~r/skipped\s*\(not authenticated\)/i,
               "expected response to indicate remote sync was skipped, got:\n#{body}"

        {:ok, Map.put(context, :response_body, body)}
      end

      and_ "local file and component sync ran to completion", context do
        body = context.response_body

        assert body =~ ~r/Files:\s*\d+/,
               "expected response to report a file count, got:\n#{body}"

        assert body =~ ~r/Components:\s*\d+/,
               "expected response to report a component count, got:\n#{body}"

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

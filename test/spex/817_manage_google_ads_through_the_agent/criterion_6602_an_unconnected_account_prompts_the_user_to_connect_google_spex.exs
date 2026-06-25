defmodule CodeMySpecSpex.Story817.Criterion6602Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6602 — An unconnected account prompts the user to connect Google.

  Surface: the `get_campaign_performance` MCP tool called by a user who has
  not connected a Google account. Token resolution fails before any HTTP
  call, so the tool returns a readable "not connected" error rather than a
  raw crash. No cassette is involved — there is no live call.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.GoogleAds.Tools.GetCampaignPerformance

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Errors surface as readable messages" do
    scenario "An unconnected account prompts the user to connect Google" do
      given_ "a user who has not connected a Google account", context do
        # No google_integration_fixture — the user has no Google connection.
        {:ok, context}
      end

      when_ "the agent calls get_campaign_performance", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890"}

        {:reply, response, _frame} = GetCampaignPerformance.execute(params, frame)
        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the tool returns a readable error about connecting Google", context do
        assert context.text =~ "Google", "expected the error to reference Google"

        assert context.text =~ ~r/not found|connect/i,
               "expected the error to tell the user Google is not connected"

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

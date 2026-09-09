defmodule CodeMySpecSpex.Story817.Criterion6598Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6598 — An approved budget change is written to the account.

  Surface: the `update_campaign_budget` MCP tool (a mutating tool). When the
  agent calls it, the client issues a `campaignBudgets:mutate` and the tool
  returns the updated resource. The human-in-the-loop gate is Claude Code's
  per-call approval prompt — not modeled here; this spec covers the executed
  mutation. The Google Ads HTTP call is replayed from
  `test/cassettes/google/ads_update_campaign_budget.json` (no live mutation).
  """

  use CodeMySpecSpex.Case

  import ReqCassette

  alias Anubis.Server.Frame
  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools.UpdateCampaignBudget
  alias CodeMySpecSpex.Fixtures

  @dev_token "test-developer-token"
  @cassette_opts [
    cassette_dir: "test/cassettes/google",
    mode: :replay,
    match_requests_on: [:method, :uri],
    filter_request_headers: ["authorization"],
    filter_response_headers: ["set-cookie"]
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "AI proposes, humans approve" do
    scenario "An approved budget change is written to the account" do
      given_ "a connected Google Ads account with a campaign", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "the agent calls update_campaign_budget with a new daily amount", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890", budget_id: "111", amount_micros: 25_000_000}

        response =
          with_ads_cassette("ads/update_campaign_budget", fn ->
            {:reply, response, _frame} = UpdateCampaignBudget.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "a campaign budget mutation is sent to Google Ads and the updated resource is returned",
            context do
        assert context.text =~ "Campaign budget updated."
        assert context.text =~ "campaignBudgets/111", "expected the mutated budget resource name"
        {:ok, context}
      end
    end
  end

  defp with_ads_cassette(name, fun) do
    with_cassette(name, @cassette_opts, fn plug ->
      original = Application.get_env(:code_my_spec, Ads, [])
      Application.put_env(:code_my_spec, Ads, Keyword.put(original, :plug, plug))
      ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, original) end)

      fun.()
    end)
  end
end

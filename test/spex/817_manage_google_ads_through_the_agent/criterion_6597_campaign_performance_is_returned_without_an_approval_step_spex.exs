defmodule CodeMySpecSpex.Story817.Criterion6597Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6597 — Campaign performance is returned without an approval step.

  Surface: the `get_campaign_performance` MCP tool. Read tools run
  automatically; calling the tool against a connected account returns the
  campaigns' spend and conversion metrics. The Google Ads HTTP call is
  replayed from `test/cassettes/google/ads_get_campaign_performance.json`
  (no live API call). The connected-account precondition is established as
  ambient scaffolding via `google_integration_fixture`, the same way login
  is scaffolded; the behavior under test runs through the real tool surface.
  """

  use CodeMySpecSpex.Case

  import ReqCassette

  alias Anubis.Server.Frame
  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools.GetCampaignPerformance
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

  spex "Read tools run automatically" do
    scenario "Campaign performance is returned without an approval step" do
      given_ "a connected Google Ads account with active campaigns", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "the agent calls get_campaign_performance for the account", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890"}

        response =
          with_ads_cassette("ads/get_campaign_performance", fn ->
            {:reply, response, _frame} = GetCampaignPerformance.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the response contains the campaigns' spend and conversion metrics", context do
        assert context.text =~ "campaign row(s)"
        assert context.text =~ "costMicros", "expected spend metrics in the response"
        assert context.text =~ "conversions", "expected conversion metrics in the response"
        {:ok, context}
      end
    end
  end

  # Injects the ReqCassette plug into the Ads client's config for the call,
  # preserving the configured developer token. Replay-only — no live calls.
  defp with_ads_cassette(name, fun) do
    with_cassette(name, @cassette_opts, fn plug ->
      original = Application.get_env(:code_my_spec, Ads, [])
      Application.put_env(:code_my_spec, Ads, Keyword.put(original, :plug, plug))
      ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, original) end)

      fun.()
    end)
  end
end

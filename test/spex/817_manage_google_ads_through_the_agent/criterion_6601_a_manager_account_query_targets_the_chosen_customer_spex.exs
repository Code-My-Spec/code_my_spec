defmodule CodeMySpecSpex.Story817.Criterion6601Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6601 — A manager account query targets the chosen customer.

  Surface: the `get_campaign_performance` MCP tool with a `login_customer_id`
  (the manager/MCC account) and a `customer_id` (the linked account to act
  on). The client scopes the request to the chosen customer (the customer id
  is part of the request URL; the login-customer-id rides as a header) and
  returns that customer's campaigns. Replayed from
  `test/cassettes/google/ads_get_campaign_performance.json`.
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

  spex "Manager account scoping" do
    scenario "A manager account query targets the chosen customer" do
      given_ "a connected manager account that can access a linked customer", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "the agent calls get_campaign_performance for that customer id", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}

        params = %{
          customer_id: "123-456-7890",
          login_customer_id: "999-888-7777"
        }

        response =
          with_ads_cassette("ads/get_campaign_performance", fn ->
            {:reply, response, _frame} = GetCampaignPerformance.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the request is scoped to that customer and returns its campaigns", context do
        assert context.text =~ "campaign row(s)"
        assert context.text =~ "Search - Brand", "expected the chosen customer's campaigns"
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

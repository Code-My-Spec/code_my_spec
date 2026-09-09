defmodule CodeMySpecSpex.Story817.Criterion6603Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6603 — A quota error surfaces the API's message.

  Surface: the `get_campaign_performance` MCP tool against a connected
  account, where the Google Ads API returns a 403 quota error. The tool
  surfaces the status and the API's message as a readable error rather than
  crashing. The error response is replayed from
  `test/cassettes/google/ads_quota_error.json`.
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

  spex "Errors surface as readable messages" do
    scenario "A quota error surfaces the API's message" do
      given_ "a connected Google Ads account", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "a performance query hits the Google Ads quota limit", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890"}

        response =
          with_ads_cassette("ads/quota_error", fn ->
            {:reply, response, _frame} = GetCampaignPerformance.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the tool returns a readable error including the API's status and message", context do
        assert context.text =~ "403", "expected the HTTP status in the error"

        assert context.text =~ "Resource has been exhausted",
               "expected the API's message surfaced in the error"

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

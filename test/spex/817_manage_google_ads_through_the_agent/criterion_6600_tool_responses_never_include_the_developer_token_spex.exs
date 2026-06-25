defmodule CodeMySpecSpex.Story817.Criterion6600Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6600 — Tool responses never include the developer token.

  Surface: a read tool (`get_campaign_performance`) with a server-side
  developer token configured. The developer token travels only as a request
  header to Google; it must never appear in the rendered tool response. The
  Google Ads HTTP call is replayed from
  `test/cassettes/google/ads_get_campaign_performance.json`.
  """

  use CodeMySpecSpex.Case

  import ReqCassette

  alias Anubis.Server.Frame
  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools.GetCampaignPerformance
  alias CodeMySpecSpex.Fixtures

  @dev_token "super-secret-developer-token"
  @cassette_opts [
    cassette_dir: "test/cassettes/google",
    mode: :replay,
    match_requests_on: [:method, :uri],
    filter_request_headers: ["authorization"],
    filter_response_headers: ["set-cookie"]
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Developer token is server-side only" do
    scenario "Tool responses never include the developer token" do
      given_ "a connected Google Ads account and a server-side developer token", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "the agent calls a read tool", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890"}

        response =
          with_ads_cassette("ads/get_campaign_performance", fn ->
            {:reply, response, _frame} = GetCampaignPerformance.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the developer token value does not appear anywhere in the response", context do
        # The call succeeded (real data is present)...
        assert context.text =~ "campaign row(s)"
        # ...yet the server-side developer token is nowhere in the output.
        refute context.text =~ @dev_token, "developer token leaked into the tool response"
        {:ok, context}
      end
    end
  end

  defp with_ads_cassette(name, fun) do
    with_cassette name, @cassette_opts, fn plug ->
      original = Application.get_env(:code_my_spec, Ads, [])
      Application.put_env(:code_my_spec, Ads, Keyword.put(original, :plug, plug))

      try do
        fun.()
      after
        Application.put_env(:code_my_spec, Ads, original)
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

defmodule CodeMySpecSpex.Story817.Criterion6599Spex do
  @moduledoc """
  Story 817 — Manage Google Ads through the agent
  Criterion 6599 — Queries use the authenticated user's own Google credentials.

  Surface: the `get_account_overview` MCP tool. The tool resolves the Google
  token from the call's scope (the authenticated user's own integration) and
  returns only that account's data — the basis of per-tenant isolation. A
  user with no connected account can reach nothing (see criterion 6602). The
  Google Ads HTTP call is replayed from
  `test/cassettes/google/ads_get_account_overview.json`.
  """

  use CodeMySpecSpex.Case

  import ReqCassette

  alias Anubis.Server.Frame
  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools.GetAccountOverview
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

  spex "Per-tenant isolation" do
    scenario "Queries use the authenticated user's own Google credentials" do
      given_ "a user who has connected their own Google Ads account", context do
        Application.put_env(:code_my_spec, Ads, developer_token: @dev_token)
        ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)

        Fixtures.google_integration_fixture(context.user, %{
          granted_scopes: ["https://www.googleapis.com/auth/adwords"]
        })

        {:ok, context}
      end

      when_ "that user's agent calls get_account_overview", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        params = %{customer_id: "123-456-7890"}

        response =
          with_ads_cassette("ads/get_account_overview", fn ->
            {:reply, response, _frame} = GetAccountOverview.execute(params, frame)
            response
          end)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "the call returns that user's own account data", context do
        assert context.text =~ "Account overview."
        assert context.text =~ "Acme Co", "expected the connected account's data in the response"
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

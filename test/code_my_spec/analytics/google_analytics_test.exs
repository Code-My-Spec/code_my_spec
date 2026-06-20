defmodule CodeMySpec.Analytics.GoogleAnalyticsTest do
  @moduledoc """
  Cassette-backed test for the Measurement Protocol HTTP delivery path.

  The cassette captures one real round-trip to
  https://www.google-analytics.com/mp/collect so the test catches breakage
  in the wire format (payload shape, URL params, headers) without ever
  POSTing to GA on subsequent runs.

  Re-record: delete `test/cassettes/analytics/ga4_mp_sign_up.json`, ensure
  GA4_MEASUREMENT_ID and GA4_MP_API_SECRET are loaded from envs/test.env,
  then `mix test test/code_my_spec/analytics/google_analytics_test.exs`.
  The api_secret is stripped from the cassette before write.
  """

  use ExUnit.Case, async: false

  import ReqCassette

  alias CodeMySpec.Analytics.GoogleAnalytics

  @cassette_dir "test/cassettes/analytics"

  setup do
    original_plug =
      Application.get_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, [])
      |> Keyword.get(:plug)

    on_exit(fn ->
      Application.put_env(
        :code_my_spec,
        GoogleAnalytics.HTTPAdapter,
        plug: original_plug
      )
    end)

    :ok
  end

  test "dispatching :sign_up POSTs a GA4 MP envelope to /mp/collect" do
    with_cassette "ga4_mp_sign_up", cassette_opts(), fn plug ->
      with_plug(plug, fn ->
        # Trip the full stack: telemetry → GoogleAnalytics.handle_event →
        # HTTPAdapter.post → Req with our injected plug → ReqCassette
        CodeMySpec.Analytics.dispatch(:sign_up, %{
          user_id: 9001,
          method: "oauth_github"
        })
      end)
    end
  end

  defp with_plug(plug, fun) do
    # The `setup` block restores the original plug via on_exit after every
    # test, so this only needs to install it for the duration of the test body.
    Application.put_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, plug: plug)
    fun.()
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        # api_secret is sent as a query param and must never land in the cassette
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end

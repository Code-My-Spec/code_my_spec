defmodule CodeMySpecSpex.Story812.Criterion6504Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6504 — Rule 2: Register page mount dispatches
  `:view_register_page` once on connected mount.

  Connected mount on /users/register fires `Analytics.dispatch/3` for
  `:view_register_page` (origin: :server). One MP POST per visit.

  ## Recording

      mix test test/spex/812_.../criterion_6504_*.exs --include ga_cassette_record

  Cassette: `test/cassettes/analytics/812_view_register_page.json`.
  """

  use CodeMySpecSpex.Case

  # /users/register lives on the main web router, not LocalWeb.
  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_view_register_page"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "Register page mount dispatches :view_register_page" do
    scenario "connected mount on /users/register fires one MP POST" do
      given_ "a fresh anonymous visitor", context do
        {:ok, context}
      end

      when_ "the visitor opens /users/register", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            {:ok, _lv, _html} = live(context.conn, "/users/register")
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured the view_register_page MP POST", context do
        assert_cassette_contains_mp_event(@cassette_name, "view_register_page",
          cassette_dir: @cassette_dir
        )

        {:ok, context}
      end
    end
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end

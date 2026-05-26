defmodule CodeMySpecSpex.Story812.Criterion6539Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6539 — Rule f9b2c751 (hybrid): server MP conversions carry
  the visitor's gtag client_id AND session_id so they stitch to the same
  GA4 session as the browser pageviews.

  Criterion 6538 covers the client_id half (from the `_ga` cookie). This
  covers the session_id half: GA4 keeps the session id in the
  `_ga_<container>` cookie, where the container suffix is the measurement_id
  minus its `G-` prefix. Two cookie formats are live in the wild and both
  must parse:

    - GS2 (current gtag.js): `GS2.<depth>.s<session_id>$o..$g..$t..$..`
      e.g. `GS2.1.s1779821354$o1$g0$t1779821354$j60$l0$h0` (verified in a
      real browser during QA — the parser originally only handled GS1 and
      silently dropped session_id on live traffic)
    - GS1 (legacy): `GS1.<depth>.<session_id>.<...>`

  Surface, not internals: the `GaClientId` plug reads the `_ga_<container>`
  cookie on the browser-pipeline request, stashes the session_id in the
  session, registration.ex threads it into the dispatch, and the MP payload
  builder places it in the event `params` (GA4's required location). We seed
  the cookie on the conn, drive the real registration LiveView, and assert
  the captured MP payload via the GA test subscriber — no cassette, no real
  GA round-trip.

  engagement_time_msec is deliberately NOT sent on server conversions — the
  gtag session is already engaged, and adding fake engagement time would
  inflate session duration.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpecSpex.Fixtures

  @ga_cookie "GA1.1.987654321.1700000000"

  # Current gtag.js session cookie format (captured from a live browser).
  @gs2_cookie "GS2.1.s1779821354$o1$g0$t1779821354$j60$l0$h0"
  @gs2_session_id "1779821354"

  # Legacy session cookie format — still supported.
  @gs1_cookie "GS1.1.1788888888.3.1.1788888899.0.0.0"
  @gs1_session_id "1788888888"

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Server MP sign_up carries the gtag session_id from the _ga session cookie" do
    scenario "GS2 cookie (current gtag format) → session_id in the sign_up MP params" do
      given_ "a conn seeded with _ga + a GS2 _ga_<container> cookie", context do
        {:ok, seed_cookies(context, @gs2_cookie)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        submit_registration(context)
        {:ok, context}
      end

      then_ "the sign_up MP payload carries the GS2 session_id", context do
        assert_sign_up_session_id(@gs2_session_id, @gs2_cookie)
        {:ok, context}
      end
    end

    scenario "GS1 cookie (legacy format) → session_id in the sign_up MP params" do
      given_ "a conn seeded with _ga + a GS1 _ga_<container> cookie", context do
        {:ok, seed_cookies(context, @gs1_cookie)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        submit_registration(context)
        {:ok, context}
      end

      then_ "the sign_up MP payload carries the GS1 session_id", context do
        assert_sign_up_session_id(@gs1_session_id, @gs1_cookie)
        {:ok, context}
      end
    end
  end

  # -- Helpers --

  defp seed_cookies(context, session_cookie) do
    email = "spex-812-session-#{System.unique_integer([:positive])}@codemyspec.test"

    conn =
      context.conn
      |> Plug.Test.put_req_cookie("_ga", @ga_cookie)
      |> Plug.Test.put_req_cookie(ga_session_cookie_name(), session_cookie)

    context |> Map.put(:email, email) |> Map.put(:conn, conn)
  end

  defp submit_registration(context) do
    {:ok, lv, _html} = live(context.conn, "/users/register")

    lv
    |> form("#registration_form", user: %{email: context.email})
    |> render_submit()
  end

  defp assert_sign_up_session_id(expected, source_cookie) do
    assert_receive {:ga_measurement_protocol,
                    %{events: [%{name: "sign_up", params: params} | _]}},
                   1_000

    assert params["session_id"] == expected,
           """
           Expected the sign_up MP event params to carry session_id=#{expected},
           parsed from the _ga_<container> cookie #{source_cookie}.

           Got: #{inspect(params["session_id"])}

           session_id must live inside the event params (not the payload root)
           so the conversion stitches to the browser's gtag session.
           """
  end

  # Container suffix = configured measurement_id sans the "G-" prefix — the
  # same derivation the GaClientId plug uses, so the seeded cookie name matches.
  defp ga_session_cookie_name do
    "G-" <> container =
      Application.get_env(:code_my_spec, GoogleAnalytics)[:measurement_id]

    "_ga_" <> container
  end
end

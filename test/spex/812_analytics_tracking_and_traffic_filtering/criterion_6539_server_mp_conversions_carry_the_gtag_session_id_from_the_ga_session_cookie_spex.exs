defmodule CodeMySpecSpex.Story812.Criterion6539Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6539 — Rule f9b2c751 (hybrid): server MP conversions carry
  the visitor's gtag client_id AND session_id so they stitch to the same
  GA4 session as the browser pageviews.

  Criterion 6538 covers the client_id half (from the `_ga` cookie). This
  covers the session_id half: GA4 keeps the session id in the
  `_ga_<container>` cookie — `GS1.<depth>.<session_id>.<...>` — where the
  container suffix is the measurement_id minus its `G-` prefix. Without a
  session_id, the server conversion attaches to the right user but a
  different (or new) session, fragmenting the funnel.

  Surface, not internals: the `GaClientId` plug reads the `_ga_<container>`
  cookie on the browser-pipeline request, stashes the session_id in the
  session, registration.ex threads it into the dispatch, and the MP payload
  builder places it in the event `params` (GA4's required location for
  session_id). We seed the cookie on the conn, drive the real registration
  LiveView, and assert the captured MP payload via the GA test subscriber —
  no cassette, no real GA round-trip.

  We assert session_id only; engagement_time_msec is deliberately NOT sent
  on server conversions — the gtag session is already engaged, and adding
  fake engagement time would inflate session duration.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpecSpex.Fixtures

  # _ga (client_id) + _ga_<container> (session) cookies as gtag writes them.
  @ga_cookie "GA1.1.987654321.1700000000"
  @ga_session_cookie "GS1.1.1788888888.3.1.1788888899.0.0.0"
  @expected_session_id "1788888888"

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Server MP sign_up carries the gtag session_id from the _ga session cookie" do
    scenario "sign_up MP payload includes session_id parsed from the _ga_<container> cookie" do
      given_ "a fresh email and a conn seeded with _ga + _ga_<container> cookies", context do
        email = "spex-812-session-#{System.unique_integer([:positive])}@codemyspec.test"

        conn =
          context.conn
          |> Plug.Test.put_req_cookie("_ga", @ga_cookie)
          |> Plug.Test.put_req_cookie(ga_session_cookie_name(), @ga_session_cookie)

        {:ok, context |> Map.put(:email, email) |> Map.put(:conn, conn)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        {:ok, lv, _html} = live(context.conn, "/users/register")

        lv
        |> form("#registration_form", user: %{email: context.email})
        |> render_submit()

        {:ok, context}
      end

      then_ "the sign_up MP payload carries session_id in its event params", context do
        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "sign_up", params: params} | _]}},
                       1_000

        assert params["session_id"] == @expected_session_id,
               """
               Expected the sign_up MP event params to carry
               session_id=#{@expected_session_id}, parsed from the
               _ga_<container> session cookie #{@ga_session_cookie}.

               Got: #{inspect(params["session_id"])}

               session_id must live inside the event params (not the payload
               root) so the conversion stitches to the browser's gtag session.
               """

        {:ok, context}
      end
    end
  end

  # Container suffix = configured measurement_id sans the "G-" prefix — the
  # same derivation the GaClientId plug uses, so the seeded cookie name matches.
  defp ga_session_cookie_name do
    "G-" <> container =
      Application.get_env(:code_my_spec, GoogleAnalytics)[:measurement_id]

    "_ga_" <> container
  end
end

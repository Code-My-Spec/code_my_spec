defmodule CodeMySpecSpex.Story812.Criterion6510Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6510 — Rule 3: OAuth :existing via email auto-link is
  silent — no `:sign_up` dispatched.

  Telemetry-subscriber pattern (companion to 6509). When no
  provider-identity match exists but the OAuth email matches an
  existing users row, `find_or_register_by_email` returns the
  existing user with `:existing` and the integration is auto-linked.
  Returning users must never re-trigger `:sign_up`.

  Setup: pre-create a user with the email the OAuth callback will
  carry, NO matching Google integration. Drive callback. `refute_receive`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.{Fixtures, OAuthHelpers}

  # Fixtures FIRST — user_fixture dispatches :sign_up (magic_link)
  # during creation. Attaching the subscriber before seeding fixtures
  # would land that spurious dispatch in the mailbox and falsely trip
  # the refute_receive later.
  setup do
    unique = System.unique_integer([:positive])
    email = "google-emailmatch-812-#{unique}@example.com"

    user = Fixtures.user_fixture(%{email: email})

    user_claims = %{
      "sub" => "google-sub-812-email-#{unique}",
      "email" => email,
      "email_verified" => true,
      "name" => "OAuth Email Match"
    }

    oauth_cassette = "google_812_oauth_email_link_#{unique}"
    OAuthHelpers.build_google_cassette!(oauth_cassette, user_claims)

    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)

    {:ok, user: user, oauth_cassette: oauth_cassette}
  end

  spex "OAuth :existing via email auto-link is silent" do
    scenario "email match on a user with no Google integration fires no :sign_up" do
      given_ "the user is already on file with that email", context do
        # given: already true — the `setup` block above creates the user with
        # this email via `Fixtures.user_fixture/1`, and deliberately no Google
        # integration: matching by email alone is what this criterion is about.
        {:ok, context}
      end

      when_ "the OAuth callback completes with that matching email", context do
        conn =
          OAuthHelpers.do_google_callback(
            Phoenix.ConnTest.build_conn(),
            context.oauth_cassette,
            "state-812-email"
          )

        {:ok, Map.put(context, :callback, conn)}
      end

      # The anchor, and it carries more weight here than in 6509. This criterion
      # turns on the auto-link *finding* the existing user by email — there is no
      # Google integration to match on — and a callback that failed to link would
      # be just as silent as one that linked correctly. A session token says the
      # match was made and this user was logged in by it.
      then_ "the matched user is logged in", context do
        assert Plug.Conn.get_session(context.callback, :user_token),
               "the OAuth callback logged nobody in, so the refute below would hold " <>
                 "for a callback that never matched the email rather than for an " <>
                 "auto-link that worked"

        {:ok, context}
      end

      then_ "no :sign_up telemetry event is dispatched", context do
        refute_receive {:ga_measurement_protocol, %{events: [%{name: "sign_up"} | _]}},
                       250

        {:ok, context}
      end
    end
  end
end

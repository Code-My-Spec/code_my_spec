defmodule CodeMySpecSpex.Story812.Criterion6509Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6509 — Rule 3: OAuth :existing via provider identity is
  silent — no `:sign_up` dispatched.

  Telemetry-subscriber pattern for the negative assertion. When an
  existing (provider, provider_user_id) integration is mapped to a
  user, `Users.find_or_register_oauth_user/2` returns
  `{:ok, user, :existing}`. Returning users must never re-fire
  `:sign_up`, or GA double-counts signups on every subsequent login.

  Setup: pre-create user + Google integration with a known sub.
  Drive callback with same sub. `refute_receive` proves the
  dispatch never fired.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.{Fixtures, OAuthHelpers}

  # Fixtures FIRST — `Fixtures.user_fixture` calls `Users.register_user`
  # which dispatches `:sign_up` (magic_link). If the subscriber were
  # attached before this, the spurious dispatch would land in the
  # mailbox and falsely trip the `refute_receive` later. Attach
  # subscriber AFTER fixtures are seeded.
  setup do
    unique = System.unique_integer([:positive])
    sub = "google-sub-812-existing-#{unique}"
    email = "google-existing-812-#{unique}@example.com"

    user = Fixtures.user_fixture(%{email: email})

    Fixtures.google_integration_fixture(user, %{
      provider_metadata: %{"provider_user_id" => sub}
    })

    user_claims = %{
      "sub" => sub,
      "email" => email,
      "email_verified" => true,
      "name" => "OAuth Existing Returning"
    }

    oauth_cassette = "google_812_oauth_existing_#{unique}"
    OAuthHelpers.build_google_cassette!(oauth_cassette, user_claims)

    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)

    {:ok, user: user, sub: sub, oauth_cassette: oauth_cassette}
  end

  spex "OAuth :existing via provider identity is silent" do
    scenario "returning login fires no :sign_up telemetry" do
      given_ "the user + Google integration are already on file", context do
        # given: already true — the `setup` block above creates the user and a
        # Google integration carrying the same provider_user_id, through
        # `Fixtures.user_fixture/1` and `Fixtures.google_integration_fixture/2`.
        # The claim is about who exists before the callback, so it is arranged
        # once for the scenario rather than driven here.
        {:ok, context}
      end

      when_ "the OAuth callback completes for that same sub", context do
        OAuthHelpers.do_google_callback(
          Phoenix.ConnTest.build_conn(),
          context.oauth_cassette,
          "state-812-existing"
        )

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

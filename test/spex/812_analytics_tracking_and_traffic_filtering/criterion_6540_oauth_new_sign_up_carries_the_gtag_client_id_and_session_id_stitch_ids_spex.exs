defmodule CodeMySpecSpex.Story812.Criterion6540Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6540 — Rule f9b2c751 (hybrid): the OAuth :new sign_up conversion
  carries the visitor's gtag client_id AND session_id so it stitches to the
  same GA4 session as the browser pageviews — the OAuth-path equivalent of
  6538/6539 (magic-link).

  The OAuth callback route runs through the :browser pipeline, so the
  GaClientId plug writes the parsed client_id + session_id (from the _ga and
  _ga_<container> cookies the browser carries through the provider round-trip)
  into the session. The controller threads them into
  `Users.find_or_register_oauth_user/3`, which merges them into the sign_up
  MP payload.

  Test-subscriber pattern (like 6508): we call find_or_register_oauth_user/3
  directly with the stitch ids — the same domain function the callback invokes
  — and assert the captured MP payload carries them. The Assent HTTP exchange
  and the controller's session read are out of scope here (the latter mirrors
  registration.ex and is exercised by browser QA); this pins the dispatch
  contract: given the ids, the OAuth sign_up payload carries them.

  client_id is at the payload root; session_id lives in the event params
  (GA4's required location). engagement_time_msec is deliberately not sent.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  # Parsed stitch values as the session would hold them (post-plug-parse):
  # client_id = the _ga "<X>.<Y>" tail; session_id = the GS2 s<digits> value.
  @client_id "987654321.1700000000"
  @session_id "1779821354"

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "OAuth :new sign_up carries the gtag client_id and session_id" do
    scenario "a new GitHub OAuth signup's MP payload carries client_id (root) + session_id (params)" do
      given_ "a unique provider identity not yet in the database, plus stitch ids", context do
        unique = System.unique_integer([:positive])

        attrs = %{
          provider_user_id: "gh-6540-#{unique}",
          email: "github-6540-#{unique}@example.com"
        }

        {:ok, Map.put(context, :oauth_attrs, attrs)}
      end

      when_ "find_or_register_oauth_user registers the new user with the stitch ids",
            context do
        {:ok, user, :new} =
          Fixtures.find_or_register_oauth_user(:github, context.oauth_attrs,
            ga_client_id: @client_id,
            ga_session_id: @session_id
          )

        {:ok, Map.put(context, :user, user)}
      end

      then_ "the sign_up MP payload carries the client_id, session_id, and oauth method",
            context do
        assert_receive {:ga_measurement_protocol,
                        %{
                          client_id: client_id,
                          events: [%{name: "sign_up", params: params} | _]
                        }},
                       1_000

        assert client_id == @client_id,
               "expected MP client_id=#{@client_id} (the _ga cookie tail), got: #{inspect(client_id)}"

        assert params["session_id"] == @session_id,
               "expected session_id=#{@session_id} in the event params, got: #{inspect(params["session_id"])}"

        assert params["method"] == "oauth_github",
               "expected method=oauth_github, got: #{inspect(params["method"])}"

        {:ok, context}
      end
    end
  end
end

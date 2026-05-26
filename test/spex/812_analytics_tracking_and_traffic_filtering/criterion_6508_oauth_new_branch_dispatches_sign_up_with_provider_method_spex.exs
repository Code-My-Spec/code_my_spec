defmodule CodeMySpecSpex.Story812.Criterion6508Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6508 — Rule 3: OAuth :new branch dispatches sign_up with
  provider method (e.g. "oauth_github").

  Test-subscriber pattern: `Fixtures.attach_ga_test_subscriber/1` registers
  this test process to receive every GA Measurement Protocol payload as
  `{:ga_measurement_protocol, payload}`. We drive `Users.find_or_register_oauth_user/2`
  directly — the same code path the OAuth callback controller invokes — and
  assert the MP payload arrives with the correct method param.

  The OAuth Assent HTTP exchange is not involved here; we call the domain
  function directly so the test is focused on the analytics dispatch contract.
  No cassette, no real GA round-trip.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "OAuth :new branch dispatches sign_up with provider method" do
    scenario "a brand-new GitHub OAuth signup fires sign_up with method=oauth_github" do
      given_ "a unique provider identity not yet in the database", context do
        unique = System.unique_integer([:positive])

        attrs = %{
          provider_user_id: "gh-812-#{unique}",
          email: "github-812-#{unique}@example.com"
        }

        {:ok, Map.put(context, :oauth_attrs, attrs)}
      end

      when_ "Users.find_or_register_oauth_user creates a new user for that identity",
            context do
        {:ok, user, :new} = Fixtures.find_or_register_oauth_user(:github, context.oauth_attrs)
        {:ok, Map.put(context, :user, user)}
      end

      then_ "a sign_up MP payload arrives with method=oauth_github", context do
        assert_receive {:ga_measurement_protocol,
                        %{events: [%{name: "sign_up", params: params} | _]}},
                       1_000

        assert params["method"] == "oauth_github",
               "Expected sign_up MP event params to carry method=\"oauth_github\", got: #{inspect(params["method"])}"

        {:ok, context}
      end
    end
  end
end

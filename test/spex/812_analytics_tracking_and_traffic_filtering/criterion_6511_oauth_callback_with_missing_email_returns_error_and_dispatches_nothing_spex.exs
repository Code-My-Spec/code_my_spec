defmodule CodeMySpecSpex.Story812.Criterion6511Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6511 — Rule 3: OAuth callback with missing email returns
  error and dispatches nothing.

  Unit-level call into `Users.find_or_register_oauth_user/2` with
  `email: nil` and no matching provider identity. Asserts
  `{:error, :missing_email}` returns AND no `:sign_up` telemetry
  event fires (verified via subscriber).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "OAuth callback with missing email returns error and dispatches nothing" do
    scenario "find_or_register_oauth_user/2 with nil email is silent" do
      given_ "an OAuth payload with nil email and no matching provider identity",
             context do
        {:ok,
         Map.put(
           context,
           :provider_user_id,
           "google-no-email-#{System.unique_integer([:positive])}"
         )}
      end

      when_ "Users.find_or_register_oauth_user/2 is called", context do
        result =
          Fixtures.find_or_register_oauth_user(:google, %{
            provider_user_id: context.provider_user_id,
            email: nil
          })

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the call returns {:error, :missing_email}", context do
        assert context.result == {:error, :missing_email}
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

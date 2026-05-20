defmodule CodeMySpec.Users.SignupAnalyticsTest do
  @moduledoc """
  Locks the contract for when `:sign_up` is dispatched. The previous
  browser-side gtag fire on every "User confirmed successfully." flash
  produced false positives on every returning OAuth login — that whole
  signal was rebuilt server-side, anchored to actual user-row inserts.

  This test guards against regression: `:sign_up` fires exactly once per
  new user, never for returning users.
  """

  use CodeMySpecTest.DataCase

  alias CodeMySpec.Analytics
  alias CodeMySpec.Users

  import CodeMySpec.UsersFixtures

  setup do
    :ok = Analytics.attach_test_subscriber(self())
    on_exit(fn -> Analytics.detach_test_subscriber(self()) end)
    :ok
  end

  describe ":sign_up dispatch on magic-link registration" do
    test "fires once with method=magic_link when register_user succeeds" do
      email = unique_user_email()
      {:ok, user} = Users.register_user(%{email: email})

      assert_receive {:analytics_event, :sign_up, %{user_id: user_id, method: "magic_link"}}
      assert user_id == user.id

      refute_receive {:analytics_event, :sign_up, _}, 50
    end

    test "does not fire when register_user fails validation" do
      {:error, _} = Users.register_user(%{email: "not-an-email"})

      refute_receive {:analytics_event, :sign_up, _}, 50
    end
  end

  describe ":sign_up dispatch on OAuth registration" do
    test "fires with method=oauth_<provider> when new OAuth user is created" do
      attrs = %{provider_user_id: unique_provider_id(), email: unique_user_email()}

      {:ok, user, :new} = Users.find_or_register_oauth_user(:github, attrs)

      assert_receive {:analytics_event, :sign_up, %{user_id: user_id, method: "oauth_github"}}
      assert user_id == user.id
    end

    test "does NOT fire when returning user logs in via OAuth (existing integration)" do
      # Create a brand-new user via the OAuth path so the integration row
      # actually gets attached on the second call.
      provider_user_id = unique_provider_id()
      email = unique_user_email()

      {:ok, _user, :new} =
        Users.find_or_register_oauth_user(:github, %{
          provider_user_id: provider_user_id,
          email: email
        })

      # NOTE: the integration row is saved by the controller layer
      # (Integrations.save_integration) rather than by Users itself, so
      # in this unit-level test the second call will fall back to the
      # email-match branch (:existing). Either branch is "returning
      # user" and must NOT redispatch :sign_up.
      flush_analytics_messages()

      {:ok, _, :existing} =
        Users.find_or_register_oauth_user(:github, %{
          provider_user_id: provider_user_id,
          email: email
        })

      refute_receive {:analytics_event, :sign_up, _}, 100
    end

    test "does NOT fire when OAuth email matches a pre-existing user (auto-link path)" do
      existing = user_fixture()
      flush_analytics_messages()

      {:ok, _, :existing} =
        Users.find_or_register_oauth_user(:github, %{
          provider_user_id: unique_provider_id(),
          email: existing.email
        })

      refute_receive {:analytics_event, :sign_up, _}, 100
    end

    test "dispatch failure does not crash the OAuth flow" do
      # Detach our subscriber and attach one that raises. Telemetry
      # isolates handler exceptions — find_or_register_oauth_user must
      # still return {:ok, user, :new}.
      Analytics.detach_test_subscriber(self())

      :ok =
        :telemetry.attach(
          {__MODULE__, :crashing_handler},
          Analytics.telemetry_event(),
          fn _event, _meas, _meta, _ -> raise "boom" end,
          nil
        )

      on_exit(fn -> :telemetry.detach({__MODULE__, :crashing_handler}) end)

      attrs = %{provider_user_id: unique_provider_id(), email: unique_user_email()}

      assert {:ok, _user, :new} = Users.find_or_register_oauth_user(:github, attrs)
    end
  end

  defp unique_provider_id, do: "gh-#{System.unique_integer([:positive])}"

  defp flush_analytics_messages do
    receive do
      {:analytics_event, _, _} -> flush_analytics_messages()
    after
      0 -> :ok
    end
  end
end

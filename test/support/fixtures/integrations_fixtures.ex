defmodule CodeMySpec.IntegrationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Integrations` context.
  """

  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Repo

  def valid_integration_attributes(user, attrs \\ %{}) do
    Enum.into(attrs, %{
      user_id: user.id,
      provider: :github,
      access_token: "test_access_token_#{System.unique_integer([:positive])}",
      refresh_token: "test_refresh_token_#{System.unique_integer([:positive])}",
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
      granted_scopes: ["repo", "user:email"],
      provider_metadata: %{
        "provider_user_id" => "12345",
        "username" => "testuser",
        "avatar_url" => "https://example.com/avatar.png"
      }
    })
  end

  def valid_github_integration_attributes(user, attrs \\ %{}) do
    valid_integration_attributes(user, Map.merge(%{provider: :github}, attrs))
  end

  def valid_gitlab_integration_attributes(user, attrs \\ %{}) do
    valid_integration_attributes(user, Map.merge(%{provider: :gitlab}, attrs))
  end

  def valid_bitbucket_integration_attributes(user, attrs \\ %{}) do
    valid_integration_attributes(user, Map.merge(%{provider: :bitbucket}, attrs))
  end

  def expired_integration_attributes(user, attrs \\ %{}) do
    valid_integration_attributes(
      user,
      Map.merge(%{expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)}, attrs)
    )
  end

  def integration_without_refresh_token_attributes(user, attrs \\ %{}) do
    valid_integration_attributes(user, Map.merge(%{refresh_token: nil}, attrs))
  end

  def integration_fixture(user, attrs \\ %{}) do
    %Integration{}
    |> Integration.changeset(valid_integration_attributes(user, attrs))
    |> Repo.insert!()
  end

  def github_integration_fixture(user, attrs \\ %{}) do
    integration_fixture(user, Map.merge(%{provider: :github}, attrs))
  end

  def gitlab_integration_fixture(user, attrs \\ %{}) do
    integration_fixture(user, Map.merge(%{provider: :gitlab}, attrs))
  end

  def bitbucket_integration_fixture(user, attrs \\ %{}) do
    integration_fixture(user, Map.merge(%{provider: :bitbucket}, attrs))
  end

  @doc """
  Creates a Google integration row. During cassette recording the
  caller should override `access_token` with a real token via
  `GA_TEST_OAUTH_TOKEN` env var; during replay the placeholder is
  fine because the cassette serves the recorded response regardless.

  Scopes match the production OAuth request (`analytics.edit` +
  `analytics.readonly`) so `Auth.get_valid_token/1` doesn't trip the
  granted-scopes check.
  """
  def google_integration_fixture(user, attrs \\ %{}) do
    real_token = System.get_env("GA_TEST_OAUTH_TOKEN")

    base = %{
      provider: :google,
      access_token: real_token || "test_google_access_token_replay",
      granted_scopes: [
        "email",
        "profile",
        "https://www.googleapis.com/auth/analytics.edit",
        "https://www.googleapis.com/auth/analytics.readonly"
      ],
      provider_metadata: %{
        "provider_user_id" => "google_test_user_#{System.unique_integer([:positive])}"
      }
    }

    integration_fixture(user, Map.merge(base, attrs))
  end

  def expired_integration_fixture(user, attrs \\ %{}) do
    integration_fixture(user, expired_integration_attributes(user, attrs))
  end

  def integration_without_refresh_token_fixture(user, attrs \\ %{}) do
    integration_fixture(user, integration_without_refresh_token_attributes(user, attrs))
  end
end

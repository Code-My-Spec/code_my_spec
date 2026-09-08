defmodule CodeMySpec.OauthFixtures do
  @moduledoc """
  Test data for OAuth integrations.
  """

  def oauth_application_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Test Application",
        uid: "test-client-#{System.unique_integer([:positive])}",
        secret: "test-secret-#{:crypto.strong_rand_bytes(32) |> Base.encode64()}",
        redirect_uri: "https://example.com/callback",
        scopes: ""
      })

    # Insert directly without changeset since the OAuth schema doesn't expose it
    {1, [app]} =
      CodeMySpec.Repo.insert_all(
        "oauth_applications",
        [
          Map.merge(attrs, %{
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          })
        ],
        returning: [:id, :name, :uid, :secret, :redirect_uri, :scopes]
      )

    struct(CodeMySpec.Oauth.Application, app)
  end

  @doc """
  Seeds the trusted `codemyspec-cli` OAuth application used by the
  CLI's `/codemyspec:authenticate` flow. Trusted clients receive
  silent approval — see `CodeMySpecWeb.OAuthController`.
  """
  def cli_oauth_application_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "CodeMySpec CLI",
        uid: "codemyspec-cli",
        secret: "",
        redirect_uri: "http://localhost:9876/oauth/callback",
        scopes: ""
      })

    oauth_application_fixture(attrs)
  end
end

defmodule Mix.Tasks.GetJohns10Token do
  @moduledoc """
  Mix task to generate a bearer token for johns10@gmail.com

  ## Usage

      mix get_johns10_token

  """
  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Oauth.Application
  alias CodeMySpec.{Repo, Users}
  alias ExOauth2Provider.AccessTokens

  @shortdoc "Generate bearer token for johns10@gmail.com"

  def run(_) do
    Mix.Task.run("app.start")

    email = "johns10@gmail.com"

    case Users.get_user_by_email(email) do
      nil ->
        Mix.shell().error("User with email #{email} not found")
        System.halt(1)

      user ->
        with_oauth_application(email, user)
    end
  end

  defp with_oauth_application(email, user) do
    case get_or_create_oauth_application() do
      {:ok, application} ->
        with_access_token(email, user, application)

      {:error, reason} ->
        Mix.shell().error("Failed to get OAuth application: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp with_access_token(email, user, application) do
    case create_access_token(user, application) do
      {:ok, access_token} ->
        Mix.shell().info("Bearer token for #{email}:")
        Mix.shell().info(access_token.token)
        Mix.shell().info("\nToken details:")
        Mix.shell().info("  - Expires in: #{access_token.expires_in} seconds")
        Mix.shell().info("  - Scopes: #{access_token.scopes}")
        Mix.shell().info("  - Token type: Bearer")

      {:error, reason} ->
        Mix.shell().error("Failed to create access token: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_or_create_oauth_application do
    case Repo.get_by(Application, name: "Mix Task Client") do
      nil ->
        attrs = %{
          name: "Mix Task Client",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "read write",
          uid: generate_client_id(),
          secret: generate_client_secret()
        }

        %Application{}
        |> Application.changeset(attrs)
        |> Repo.insert()

      application ->
        {:ok, application}
    end
  end

  defp create_access_token(user, application) do
    # Create access token directly for the user using ExOauth2Provider
    # This bypasses the OAuth flow but creates a proper token structure
    attrs = %{
      application: application,
      scopes: "read write"
    }

    AccessTokens.create_token(user, attrs, otp_app: :code_my_spec)
  end

  defp generate_client_id,
    do: "mix_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))

  defp generate_client_secret,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end

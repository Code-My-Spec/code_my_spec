defmodule Mix.Tasks.Cms.GaTestToken do
  @moduledoc """
  Print a valid Google access token for the configured QA user, refreshing
  the underlying integration if its `expires_at` has passed.

  Reads the `:google` integration from the dev DB for the resolved user,
  routes through `CodeMySpec.Google.Auth.get_valid_token/1` (same refresh
  logic the admin and reporting clients use at runtime), and writes the
  token to stdout. Nothing else lands on stdout, so the output is safe
  to capture into an env var:

      export GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token)

  Or inline:

      GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token) \\
        mix test test/spex/812_.../criterion_6507_*.exs \\
        --include ga_cassette_record

  ## User resolution

  Defaults to `johns10@gmail.com`. Override with the `GA_TOKEN_USER_EMAIL`
  env var or by passing the email as the only positional arg:

      mix cms.ga_test_token someone@example.com

  ## Failure modes

  Exits non-zero with a stderr message when:
  - The user isn't in the DB
  - The user has no `:google` integration
  - The integration is expired and has no refresh_token
  - The refresh call to Google fails (network, revoked grant)

  Designed for the cassette-recording workflow on story 812. Not for
  general scripting — token printing is intentionally narrow.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Google.Auth
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  @shortdoc "Print a valid Google access token (refresh if expired)"

  def run(argv) do
    Mix.Task.run("app.start")

    email = resolve_email(argv)

    with {:ok, user} <- fetch_user(email),
         {:ok, token} <- Auth.get_valid_token(Scope.for_user(user)) do
      # Only the token lands on stdout — surrounding context goes to stderr
      # so `$(mix cms.ga_test_token)` captures cleanly.
      IO.write(token)
    else
      {:error, reason} ->
        IO.puts(:stderr, "cms.ga_test_token failed: #{format_error(reason)}")
        System.halt(1)
    end
  end

  defp resolve_email([email | _]) when is_binary(email) and email != "", do: email

  defp resolve_email(_argv) do
    System.get_env("GA_TOKEN_USER_EMAIL", "johns10@gmail.com")
  end

  defp fetch_user(email) do
    case Users.get_user_by_email(email) do
      nil -> {:error, {:user_not_found, email}}
      user -> {:ok, user}
    end
  end

  defp format_error({:user_not_found, email}), do: "no user with email #{email}"

  defp format_error(:not_found),
    do: "user has no :google integration (re-authorize via the integrations page)"

  defp format_error(:no_refresh_token),
    do: "google integration token is expired and has no refresh_token (re-authorize)"

  defp format_error(other), do: inspect(other)
end

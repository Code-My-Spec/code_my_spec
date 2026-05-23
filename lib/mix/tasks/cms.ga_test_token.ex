defmodule Mix.Tasks.Cms.GaTestToken do
  @moduledoc """
  Print a valid Google access token for the configured QA user, refreshing
  the underlying integration if its `expires_at` has passed.

  Reads the `:google` integration from the dev DB for the resolved user,
  routes through `CodeMySpec.Google.Auth.get_valid_token/1` (same refresh
  logic the admin and reporting clients use at runtime), and writes the
  token to stdout as the final line. Mix compile chatter may appear
  on stdout above it, so capture with `tail -n1`:

      export GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1)

  Or inline:

      GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1) \\
        mix test test/spex/812_.../criterion_6507_*.exs \\
        --include ga_cassette_record

  Tip: run `mix compile` first so compile output doesn't appear on
  the first call.

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

  require Logger

  alias CodeMySpec.Google.Auth
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope

  @shortdoc "Print a valid Google access token (refresh if expired)"

  def run(argv) do
    # Silence Logger so its output (which can land on stdout depending on
    # backend config) doesn't muddy the `$()` capture. The mix task is
    # intended for capture; user-facing messages we want them to see go
    # to stderr explicitly.
    Logger.configure(level: :error)
    Mix.Task.run("app.start")

    email = resolve_email(argv)

    with {:ok, user} <- fetch_user(email),
         {:ok, token} <- Auth.get_valid_token(Scope.for_user(user)) do
      # The token is the final line of stdout — earlier lines may be
      # Mix compile output, so callers use `tail -n1` to capture.
      IO.puts(token)
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

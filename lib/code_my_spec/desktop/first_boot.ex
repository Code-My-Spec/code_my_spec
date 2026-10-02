defmodule CodeMySpec.Desktop.FirstBoot do
  @moduledoc """
  Every desktop boot, after the Repo and before anything reads it (bb8bc042
  step 6): migrate, ensure the desktop user and an account it owns, and hand
  the in-tree harness a token for that user. Idempotent; returns `:ignore`
  so it occupies no process.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Desktop,
      CodeMySpec.Oauth,
      CodeMySpec.Release,
      CodeMySpec.Repo,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users
    ]

  import Ecto.Query

  alias CodeMySpec.Accounts
  alias CodeMySpec.Desktop
  alias CodeMySpec.Oauth.AccessToken
  alias CodeMySpec.Repo
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias CodeMySpec.Users.User

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :run, []}, restart: :temporary}

  def run do
    require_pgvector!()
    CodeMySpec.Release.migrate()
    user = ensure_user()
    ensure_account(user)
    Application.put_env(:code_my_spec, :harness_token, ensure_token(user).token)
    :ignore
  end

  defp require_pgvector! do
    if Repo.query!("SELECT 1 FROM pg_available_extensions WHERE name = 'vector'").num_rows == 0 do
      raise "CodeMySpec needs the pgvector extension in this Postgres. " <>
              "Install it (macOS: `brew install pgvector`; Debian: `apt install postgresql-<ver>-pgvector`) and restart."
    end
  end

  defp ensure_user do
    with nil <- Users.get_user_by_email(Desktop.email()) do
      {:ok, user} = Users.register_user(%{email: Desktop.email()})
      user |> User.confirm_changeset() |> Repo.update!()
    end
  end

  defp ensure_account(user) do
    scope = UserPreferences.scope_for(user)

    if Accounts.list_accounts(scope) == [],
      do: {:ok, _} = Accounts.create_account(scope, %{name: "Local"})
  end

  # Reused, not minted per boot: one non-expiring, app-less token per desktop
  # user. The harness holds it for the life of the process, so an expiring
  # one would drop the socket mid-session.
  defp ensure_token(user) do
    Repo.one(
      from t in AccessToken,
        where: t.resource_owner_id == ^user.id and is_nil(t.application_id),
        where: is_nil(t.expires_in) and is_nil(t.revoked_at),
        limit: 1
    ) || mint_token(user)
  end

  defp mint_token(user) do
    {:ok, token} =
      ExOauth2Provider.AccessTokens.create_token(user, %{expires_in: nil}, otp_app: :code_my_spec)

    token
  end
end

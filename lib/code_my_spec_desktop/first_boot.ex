defmodule CodeMySpecDesktop.FirstBoot do
  @moduledoc """
  Every desktop boot, after the Repo and before anything reads it (bb8bc042
  step 6): migrate and ensure the desktop user. The user creates and names
  their account during /app onboarding.
  The harness obtains its own credential through device authorization.
  Idempotent; returns `:ignore` so it occupies no process.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.UserPreferences.DesktopUser
  alias CodeMySpec.Users
  alias CodeMySpec.Users.User

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :run, []}, restart: :temporary}

  def run do
    CodeMySpec.Release.migrate()
    ensure_user()
    :ignore
  end

  @doc """
  Creates the database if it is missing. Called before the tree starts: the
  Repo's pool, started against a database that does not exist yet, would sit
  in reconnect backoff when `run/0` first queries it.
  """
  def ensure_database do
    case Repo.__adapter__().storage_up(Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create the CodeMySpec database: #{inspect(reason)}"
    end
  end

  defp ensure_user do
    with nil <- Users.get_user_by_email(DesktopUser.email()) do
      {:ok, user} = Users.register_user(%{email: DesktopUser.email()})
      user |> User.confirm_changeset() |> Repo.update!()
    end
  end
end

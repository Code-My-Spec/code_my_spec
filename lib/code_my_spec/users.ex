defmodule CodeMySpec.Users do
  @moduledoc """
  The Users context.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.Analytics,
      CodeMySpec.ClientUsers.ClientUser,
      CodeMySpec.Environments,
      CodeMySpec.Integrations,
      CodeMySpec.Mailer,
      CodeMySpec.Projects,
      CodeMySpec.Repo
    ],
    exports: :all

  import Ecto.Query, warn: false
  alias CodeMySpec.Repo

  alias CodeMySpec.Users.{User, UserNotifier, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Returns true if the user's CLI has ever joined Presence at least
  once (i.e. `cli_first_connected_at` is set).
  """
  def cli_ever_connected?(%User{cli_first_connected_at: nil}), do: false
  def cli_ever_connected?(%User{}), do: true

  @doc """
  Stamps `cli_first_connected_at` on the user if it isn't already set.
  Idempotent: a no-op for users who have already connected.
  Returns the (possibly updated) user struct.
  """
  def mark_cli_first_connect(%User{cli_first_connected_at: %DateTime{}} = user), do: {:ok, user}

  def mark_cli_first_connect(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(%{cli_first_connected_at: now})
    |> Repo.update()
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs, opts \\ []) do
    case %User{}
         |> User.email_changeset(attrs)
         |> Repo.insert() do
      {:ok, user} = ok ->
        payload =
          %{user_id: user.id, method: "magic_link"}
          |> put_ga_stitch(opts)

        CodeMySpec.Analytics.dispatch(:sign_up, payload)
        ok

      {:error, _} = err ->
        err
    end
  end

  # Thread the visitor's gtag stitch identifiers (read from the _ga / _ga_<id>
  # cookies via GaClientId plug → session → registration.ex opts) into the MP
  # conversion payload so it attaches to the same GA4 session (rule f9b2c751).
  defp put_ga_stitch(payload, opts) do
    payload
    |> maybe_put(:ga_client_id, Keyword.get(opts, :ga_client_id))
    |> maybe_put(:ga_session_id, Keyword.get(opts, :ga_session_id))
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, _key, ""), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  @doc """
  Finds an existing user by OAuth provider identity or email, or registers a new one.

  Lookup order:
  1. Integration with matching provider + provider_user_id → existing user
  2. User with matching email → auto-link
  3. No match → create new auto-confirmed user (no password)

  Returns `{:ok, user, :existing | :new}`.
  """
  def find_or_register_oauth_user(
        provider,
        %{provider_user_id: provider_user_id, email: email},
        opts \\ []
      ) do
    alias CodeMySpec.Integrations.IntegrationRepository

    result =
      case IntegrationRepository.find_user_id_by_provider_identity(provider, provider_user_id) do
        user_id when is_integer(user_id) ->
          {:ok, get_user!(user_id), :existing}

        nil ->
          find_or_register_by_email(email)
      end

    with {:ok, user, :new} <- result do
      payload =
        %{user_id: user.id, method: "oauth_#{provider}"}
        |> put_ga_stitch(opts)

      CodeMySpec.Analytics.dispatch(:sign_up, payload)
    end

    result
  end

  defp find_or_register_by_email(nil), do: {:error, :missing_email}
  defp find_or_register_by_email(""), do: {:error, :missing_email}

  defp find_or_register_by_email(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user, :existing}
      nil -> register_oauth_user(%{email: email})
    end
  end

  defp register_oauth_user(attrs) do
    case %User{}
         |> User.email_changeset(attrs)
         |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
         |> Repo.insert() do
      {:ok, user} -> {:ok, user, :new}
      {:error, changeset} -> {:error, changeset}
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `CodeMySpec.Users.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `CodeMySpec.Users.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      #
      # Refused, not raised. The refusal is right — allowing it is the
      # vulnerability this names — but raising made the *only remaining door*
      # for this user a 500 stack trace. The password form is gone from
      # `/users/log-in`, so an account with a password and no confirmation had
      # no way in at all: one door removed, the other throwing.
      #
      # It is reachable without any special setup — register with a password,
      # request a magic link before confirming — and it is what every QA pass
      # hit, because the seed user is created exactly this way.
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        {:error, :unconfirmed_with_password}

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/app/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end

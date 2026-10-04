defmodule CodeMySpec.UserPreferences do
  @moduledoc """
  The UserPreferences context.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query, warn: false
  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo

  alias CodeMySpec.UserPreferences.UserPreference
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User

  @doc """
  The scope for a signed-in user, with their saved active account and project.

  Returns nil if no user is given. Lives here, not on `Scope` or in `Users`:
  it is these preferences that fill the scope in. On `Scope` it made every
  context that takes a scope depend on preferences; in `Users` it closed a
  cycle, since `Accounts` reads `Users` and preferences read `Accounts`.
  """
  @spec scope_for(User.t() | nil) :: Scope.t() | nil
  def scope_for(%User{} = user) do
    scope = %Scope{user: user, user_id: user.id}

    case get_user_preference(scope) do
      {:ok, preferences} ->
        # The active project is a *fallback*, not the answer. Every LiveView
        # under /app/projects/:project_id gets its project from the URL, put on
        # the scope per-request by the PortableHosts, which overwrite whatever
        # is here — so the bug this used to cause (a link landing on a page
        # showing a different project than the one it named) stays fixed.
        #
        # It is still read because the REST API has no project in its URL:
        # /api/issues is what `Issues.RemoteClient` calls from the shipped CLI,
        # and IssuesRepository.resolve_project_id/1 has no other way to know
        # which project a request means. Removing it 500s that endpoint.
        # Deleting this for real means project-scoping the API routes, which
        # is a breaking change for CLIs already in the field.
        %Scope{
          user: user,
          user_id: user.id,
          active_account: preferences.active_account,
          active_account_id: preferences.active_account_id,
          active_project: preferences.active_project,
          active_project_id: preferences.active_project_id
        }

      {:error, :not_found} ->
        scope
    end
  end

  def scope_for(nil), do: nil

  @doc """
  Subscribes to scoped notifications about user_preference changes.

  The broadcasted messages match the pattern:

    * {:created, %UserPreference{}}
    * {:updated, %UserPreference{}}
    * {:deleted, %UserPreference{}}

  """
  def subscribe_user_preferences(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:user_preferences")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:user_preferences", message)
  end

  @doc """
  Gets user preferences for the scoped user.

  Returns {:ok, %UserPreference{}} if preferences exist, or {:error, :not_found} if they don't.

  ## Examples

      iex> get_user_preference(scope)
      {:ok, %UserPreference{}}

      iex> get_user_preference(scope)
      {:error, :not_found}

  """
  def get_user_preference(%Scope{} = scope) do
    UserPreference
    |> preload([:active_account, :active_project])
    |> Repo.get_by(user_id: scope.user.id)
    |> case do
      nil -> {:error, :not_found}
      user_preference -> {:ok, user_preference}
    end
  end

  @doc """
  Gets user preferences for the scoped user.

  Raises `Ecto.NoResultsError` if the User preference does not exist.

  ## Examples

      iex> get_user_preference!(scope)
      %UserPreference{}

      iex> get_user_preference!(scope)
      ** (Ecto.NoResultsError)

  """
  def get_user_preference!(%Scope{} = scope) do
    UserPreference
    |> preload([:active_account, :active_project])
    |> Repo.get_by!(user_id: scope.user.id)
  end

  @doc """
  Creates user preferences for the scoped user.

  ## Examples

      iex> create_user_preferences(scope, %{field: value})
      {:ok, %UserPreference{}}

      iex> create_user_preferences(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_preferences(%Scope{} = scope, attrs) do
    %UserPreference{}
    |> UserPreference.changeset(attrs, scope)
    |> Repo.insert()
    |> case do
      {:ok, user_preference} ->
        user_preference = Repo.preload(user_preference, [:active_account, :active_project])
        broadcast(scope, {:created, user_preference})
        {:ok, user_preference}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates user preferences for the scoped user.

  ## Examples

      iex> update_user_preferences(scope, %{field: new_value})
      {:ok, %UserPreference{}}

      iex> update_user_preferences(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_preferences(%Scope{} = scope, attrs) do
    user_preference = get_user_preference!(scope)

    user_preference
    |> UserPreference.changeset(attrs, scope)
    |> Repo.update()
    |> case do
      {:ok, user_preference} ->
        user_preference = Repo.preload(user_preference, [:active_account, :active_project])
        broadcast(scope, {:updated, user_preference})
        {:ok, user_preference}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes user preferences for the scoped user.

  ## Examples

      iex> delete_user_preferences(scope)
      {:ok, %UserPreference{}}

      iex> delete_user_preferences(scope)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_preferences(%Scope{} = scope) do
    user_preference = get_user_preference!(scope)

    with {:ok, user_preference = %UserPreference{}} <-
           Repo.delete(user_preference) do
      broadcast(scope, {:deleted, user_preference})
      {:ok, user_preference}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_preference changes.

  ## Examples

      iex> change_user_preferences(scope)
      %Ecto.Changeset{data: %UserPreference{}}

  """
  def change_user_preferences(%Scope{} = scope, attrs \\ %{}) do
    case get_user_preference(scope) do
      {:ok, user_preference} ->
        UserPreference.changeset(user_preference, attrs, scope)

      {:error, :not_found} ->
        UserPreference.changeset(%UserPreference{}, attrs, scope)
    end
  end

  @doc """
  Selects an active account for the user.

  Refused for an account the user has no membership on — this is the one
  place `active_account_id` is written, so it is the last line of defense
  against a caller handing it an id that came from somewhere other than the
  user's own account list (a stale token, a copy-pasted id). Without this
  check, `Scope.for_user/1` preloads whatever `active_account_id` says with
  no membership filter of its own, and the rest of the app trusts the scope.

  ## Examples

      iex> select_active_account(scope, 123)
      {:ok, %UserPreference{}}

      iex> select_active_account(scope, invalid_id)
      {:error, %Ecto.Changeset{}}

      iex> select_active_account(scope, an_account_the_user_does_not_belong_to)
      {:error, :not_a_member}

  """
  def select_active_account(%Scope{} = scope, account_id) do
    if Authorization.authorize(:read_account, scope, account_id) do
      attrs = %{active_account_id: account_id, active_project_id: nil}

      case get_user_preference(scope) do
        {:ok, _user_preference} ->
          update_user_preferences(scope, attrs)

        {:error, :not_found} ->
          scope |> create_user_preferences(attrs) |> update_if_created_meanwhile(scope, attrs)
      end
    else
      {:error, :not_a_member}
    end
  end

  # A user's first two requests at once (the desktop window and anything else
  # on a fresh database) both found no row and both inserted; the loser raised
  # on user_preferences_user_id_index and its page was a 500.
  defp update_if_created_meanwhile(
         {:error, %Ecto.Changeset{errors: errors}} = result,
         scope,
         attrs
       ) do
    if Keyword.has_key?(errors, :user_id),
      do: update_user_preferences(scope, attrs),
      else: result
  end

  defp update_if_created_meanwhile(result, _scope, _attrs), do: result

  @doc """
  Selects an active project for the user.

  Refused unless the project belongs to an account the user has membership
  on — same reasoning as `select_active_account/2`. A project has no members
  of its own, only its account does, so this is checked through the
  project's `account_id` rather than the project directly.

  ## Examples

      iex> select_active_project(scope, 456)
      {:ok, %UserPreference{}}

      iex> select_active_project(scope, invalid_id)
      {:error, %Ecto.Changeset{}}

      iex> select_active_project(scope, a_project_on_an_account_the_user_does_not_belong_to)
      {:error, :not_a_member}

  """
  def select_active_project(%Scope{} = scope, project_id) do
    with %{account_id: account_id} <- Projects.get_project_by_id(project_id),
         true <- Authorization.authorize(:read_account, scope, account_id) do
      case get_user_preference(scope) do
        {:ok, _user_preference} ->
          update_user_preferences(scope, %{active_project_id: project_id})

        {:error, :not_found} ->
          create_user_preferences(scope, %{active_project_id: project_id})
      end
    else
      _ -> {:error, :not_a_member}
    end
  end

  @doc """
  Generates a new token for the user.

  ## Examples

      iex> generate_token(scope)
      {:ok, %UserPreference{}}

  """
  def generate_token(%Scope{} = scope) do
    new_token = Phoenix.Token.sign(CodeMySpecWeb.Endpoint, "user_api_token", scope.user.id)

    case get_user_preference(scope) do
      {:ok, _user_preference} ->
        update_user_preferences(scope, %{token: new_token})

      {:error, :not_found} ->
        create_user_preferences(scope, %{token: new_token})
    end
  end
end

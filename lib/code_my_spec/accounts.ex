defmodule CodeMySpec.Accounts do
  @moduledoc """
  The Accounts context.
  """

  alias CodeMySpec.Accounts.{Account, AccountsRepository, MembersRepository}
  alias CodeMySpec.Authorization
  alias CodeMySpec.Users.Scope

  @doc """
  Subscribes to scoped notifications about any account changes.

  The broadcasted messages match the pattern:

    * {:created, %Account{}}
    * {:updated, %Account{}}
    * {:deleted, %Account{}}

  """
  def subscribe_account(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:account")
  end

  @doc """
  Subscribes to scoped notifications about any member changes.

  The broadcasted messages match the pattern:

    * {:created, %Member{}}
    * {:updated, %Member{}}
    * {:deleted, %Member{}}

  """
  def subscribe_member(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:member")
  end

  defp broadcast_account(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:account", message)
  end

  defp broadcast_member(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:member", message)
  end

  @doc """
  Returns the list of accounts for the user.
  """
  def list_accounts(%Scope{} = scope) do
    MembersRepository.list_user_accounts(scope.user.id)
  end

  @doc """
  Gets a single account.

  Returns nil if the Account does not exist or user has no access.
  """
  def get_account(%Scope{} = scope, id) do
    case AccountsRepository.get_account(id) do
      nil ->
        nil

      account ->
        case Authorization.authorize(:read_account, scope, account.id) do
          false -> nil
          true -> account
        end
    end
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist or user has no access.
  """
  def get_account!(%Scope{} = scope, id) do
    account = AccountsRepository.get_account!(id)
    Authorization.authorize!(:read_account, scope, account.id)
    account
  end

  @doc """
  Gets a single account by id WITHOUT a scope-based authorization
  check. Returns `nil` if the account doesn't exist.

  For use by web plugs / supervisors that need to load the account
  before the scope has been fully constructed (e.g. mid-way through
  building a scope from a request header). Callers are responsible
  for any access check that's appropriate at the call site.
  """
  @spec get_account_by_id(any()) :: Account.t() | nil
  def get_account_by_id(id) do
    AccountsRepository.get_account(id)
  end

  @doc """
  Creates an account.

  Accounts are created explicitly during onboarding by the inline
  create-account form on `/app`. The caller (the LiveView) supplies
  the name — there is no auto-provisioned default. The account row
  is created together with an owning member row in one transaction.
  """
  def create_account(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, account} <-
           AccountsRepository.create_account_with_owner(scope.user.id, attrs) do
      broadcast_account(scope, {:created, account})
      {:ok, account}
    end
  end

  @doc """
  Updates an account.
  """
  def update_account(%Scope{} = scope, %Account{} = account, attrs) do
    Authorization.authorize!(:manage_account, scope, account.id)

    with {:ok, account} <- AccountsRepository.update_account(account, attrs) do
      broadcast_account(scope, {:updated, account})
      {:ok, account}
    end
  end

  @doc """
  Deletes an account.
  """
  def delete_account(%Scope{} = scope, %Account{} = account) do
    Authorization.authorize!(:manage_account, scope, account.id)

    with {:ok, account} <- AccountsRepository.delete_account(account) do
      broadcast_account(scope, {:deleted, account})
      {:ok, account}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking account changes.
  """
  def change_account(%Scope{} = scope, %Account{} = account, attrs \\ %{}) do
    Authorization.authorize!(:manage_account, scope, account.id)

    Account.changeset(account, attrs)
  end

  @doc """
  Lists account members.
  """
  def list_account_members(%Scope{} = scope, account_id) do
    Authorization.authorize!(:read_account, scope, account_id)

    MembersRepository.list_account_members(account_id)
  end

  @doc """
  Adds a user to an account.
  """
  def add_user_to_account(%Scope{} = scope, user_id, account_id, role \\ :member) do
    Authorization.authorize!(:manage_account, scope, account_id)

    with {:ok, member} <- MembersRepository.add_user_to_account(user_id, account_id, role) do
      broadcast_member(scope, {:created, member})
      {:ok, member}
    end
  end

  @doc """
  Removes a user from an account.
  """
  def remove_user_from_account(%Scope{} = scope, user_id, account_id) do
    Authorization.authorize!(:manage_members, scope, account_id)

    with {:ok, member} <- MembersRepository.remove_user_from_account(user_id, account_id) do
      broadcast_member(scope, {:deleted, member})
      {:ok, member}
    end
  end

  @doc """
  Updates a user's role in an account.
  """
  def update_user_role(%Scope{} = scope, user_id, account_id, role) do
    Authorization.authorize!(:manage_members, scope, account_id)

    with {:ok, member} <- MembersRepository.update_user_role(user_id, account_id, role) do
      broadcast_member(scope, {:updated, member})
      {:ok, member}
    end
  end

  @doc """
  Gets a user's role in an account.
  """
  def get_user_role(%Scope{} = scope, user_id, account_id) do
    Authorization.authorize!(:read_account, scope, account_id)

    MembersRepository.get_user_role(user_id, account_id)
  end

  @doc """
  Checks if a user has access to an account.
  """
  def user_has_account_access?(%Scope{} = scope, account_id) do
    MembersRepository.user_has_account_access?(scope.user.id, account_id)
  end

  @doc """
  Returns the scope user's own role in `account_id` (`:owner`, `:admin`,
  `:member`, ...) or `nil` when they are not a member.

  Reads only the caller's own membership, so — like
  `user_has_account_access?/2` — it does not authorize and never raises. Use it
  for nav/visibility gates; use `get_user_role/3` to read *another* user's role.
  """
  def own_role(%Scope{} = scope, account_id) do
    MembersRepository.get_user_role(scope.user.id, account_id)
  end
end

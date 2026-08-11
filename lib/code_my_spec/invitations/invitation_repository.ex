defmodule CodeMySpec.Invitations.InvitationRepository do
  @moduledoc """
  Provides data access layer for invitation entities, handling invitation creation, token management,
  status tracking, and scoped queries within the multi-tenant architecture.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Invitations.Invitation
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type invitation_attrs :: %{
          email: String.t(),
          role: account_role(),
          account_id: integer(),
          invited_by_id: integer()
        }

  @type account_role :: :owner | :admin | :member

  # Basic CRUD Operations

  @spec create_invitation(scope :: Scope.t(), attrs :: invitation_attrs()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def create_invitation(_scope, %{account_id: account_id} = attrs)
      when not is_nil(account_id) do
    %Invitation{}
    |> Invitation.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, invitation} -> {:ok, Repo.preload(invitation, :account)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lists all invitations sent to a specific email address.

  ## Examples

      iex> list_user_invitations("user@example.com")
      [%Invitation{}, ...]

  """
  @spec list_user_invitations(email :: String.t()) :: [Invitation.t()]
  def list_user_invitations(email) when is_binary(email) do
    from(i in Invitation)
    |> by_email(email)
    |> pending()
    |> not_expired()
    |> Repo.all()
  end

  # Scoped to the account, which is what both the tests and the only caller have
  # always assumed. `Invitations.cancel_invitation/3` checks that you may manage
  # `account_id`, then calls `get_invitation_for_account/2` — a name that states
  # the guarantee — and mapped a hit to `{:ok, invitation}`. Unscoped, the id was
  # the only thing that had to be right, so managing any one account let you
  # cancel any other account's invitation.
  #
  # A scope with no active account matches nothing, rather than everything.
  @spec get_invitation(scope :: Scope.t(), id :: integer()) :: Invitation.t() | nil
  def get_invitation(scope, id) do
    scope |> scoped_invitation(id) |> Repo.one()
  end

  @spec get_invitation!(scope :: Scope.t(), id :: integer()) :: Invitation.t()
  def get_invitation!(scope, id) do
    scope |> scoped_invitation(id) |> Repo.one!()
  end

  defp scoped_invitation(%Scope{active_account_id: nil}, _id),
    do: from(i in Invitation, where: false, preload: [:account])

  defp scoped_invitation(%Scope{active_account_id: account_id}, id),
    do: from(i in Invitation, where: i.id == ^id and i.account_id == ^account_id, preload: [:account])

  @spec update_invitation(scope :: Scope.t(), Invitation.t(), attrs :: map()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def update_invitation(_scope, invitation, attrs) do
    invitation
    |> Invitation.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_invitation(scope :: Scope.t(), Invitation.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def delete_invitation(_scope, invitation) do
    Repo.delete(invitation)
  end

  # Token Operations

  @spec get_invitation_by_token(token :: String.t()) :: Invitation.t() | nil
  def get_invitation_by_token(token) do
    from(i in Invitation, where: i.token == ^token, preload: [:account, :invited_by])
    |> Repo.one()
  end

  @spec token_exists?(token :: String.t()) :: boolean()
  def token_exists?(token) do
    Invitation
    |> where([i], i.token == ^token)
    |> Repo.exists?()
  end

  # Status Management

  @spec accept(scope :: Scope.t(), Invitation.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def accept(_scope, invitation) do
    update_invitation_status(invitation, :accepted_at)
  end

  @spec cancel(scope :: Scope.t(), Invitation.t()) ::
          {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def cancel(
        _scope,
        %Invitation{} = invitation
      ) do
    update_invitation_status(invitation, :cancelled_at)
  end

  defp update_invitation_status(invitation, status_field) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = %{status_field => now}

    invitation
    |> Invitation.changeset(attrs)
    |> Repo.update()
  end

  # Query Builders

  @spec by_email(query :: Ecto.Query.t(), email :: String.t()) :: Ecto.Query.t()
  def by_email(query, email) do
    where(query, [i], i.email == ^email)
  end

  @spec by_account(query :: Ecto.Query.t(), account_id :: integer()) :: Ecto.Query.t()
  def by_account(query, account_id) do
    where(query, [i], i.account_id == ^account_id)
  end

  @spec pending(query :: Ecto.Query.t()) :: Ecto.Query.t()
  def pending(query) do
    where(query, [i], is_nil(i.accepted_at) and is_nil(i.cancelled_at))
  end

  @spec not_expired(query :: Ecto.Query.t()) :: Ecto.Query.t()
  def not_expired(query) do
    now = DateTime.utc_now()
    where(query, [i], i.expires_at > ^now)
  end

  @spec accepted(query :: Ecto.Query.t()) :: Ecto.Query.t()
  def accepted(query) do
    where(query, [i], not is_nil(i.accepted_at))
  end

  @spec cancelled(query :: Ecto.Query.t()) :: Ecto.Query.t()
  def cancelled(query) do
    where(query, [i], not is_nil(i.cancelled_at))
  end

  @spec expired(query :: Ecto.Query.t()) :: Ecto.Query.t()
  def expired(query) do
    now = DateTime.utc_now()
    where(query, [i], i.expires_at <= ^now and is_nil(i.accepted_at) and is_nil(i.cancelled_at))
  end

  # Bulk Operations

  @spec cleanup_expired_invitations(days_old :: integer()) :: {integer(), nil}
  def cleanup_expired_invitations(days_old) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_old, :day)

    from(i in Invitation)
    |> where([i], i.expires_at <= ^cutoff_date)
    |> expired()
    |> Repo.delete_all()
  end

  @spec list_pending_invitations(scope :: Scope.t(), account_id :: integer()) :: [Invitation.t()]
  def list_pending_invitations(_scope, nil), do: []

  def list_pending_invitations(_scope, account_id) do
    from(i in Invitation)
    |> by_account(account_id)
    |> pending()
    |> not_expired()
    |> preload(:invited_by)
    |> Repo.all()
  end

  @spec count_pending_invitations(scope :: Scope.t(), account_id :: integer()) :: integer()
  def count_pending_invitations(_scope, account_id)
      when not is_nil(account_id) do
    from(i in Invitation)
    |> by_account(account_id)
    |> pending()
    |> not_expired()
    |> Repo.aggregate(:count, :id)
  end

  def count_pending_invitations(_scope, nil), do: 0
end

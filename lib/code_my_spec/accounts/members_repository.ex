defmodule CodeMySpec.Accounts.MembersRepository do
  @moduledoc """
  Provides data access layer for account membership relationships, handling user addition/removal,
  role management, and access control within the multi-tenant architecture.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Repo
  alias CodeMySpec.Accounts.{Account, Member}
  alias CodeMySpec.Users.User

  @type account_role :: :owner | :admin | :member

  @spec add_user_to_account(String.t(), String.t(), account_role()) ::
          {:ok, Member.t()} | {:error, Ecto.Changeset.t() | :user_limit_exceeded}
  def add_user_to_account(user_id, account_id, role \\ :member) do
    case can_add_user_to_account?(account_id) do
      true ->
        %Member{}
        |> Member.changeset(%{user_id: user_id, account_id: account_id, role: role})
        |> Repo.insert()
    end
  end

  @spec remove_user_from_account(String.t(), String.t()) ::
          {:ok, Member.t()} | {:error, :not_found}
  def remove_user_from_account(user_id, account_id) do
    case Repo.get_by(Member, user_id: user_id, account_id: account_id) do
      nil ->
        {:error, :not_found}

      member ->
        case member.role do
          :owner ->
            owner_count = count_owners(account_id)

            if owner_count > 1 do
              Repo.delete(member)
            else
              {:error, :last_owner}
            end

          _ ->
            Repo.delete(member)
        end
    end
  end

  @spec update_user_role(String.t(), String.t(), account_role()) ::
          {:ok, Member.t()} | {:error, Ecto.Changeset.t()}
  def update_user_role(user_id, account_id, role) do
    case Repo.get_by(Member, user_id: user_id, account_id: account_id) do
      nil ->
        {:error, :not_found}

      member ->
        changeset = Member.update_role_changeset(member, %{role: role})
        validated_changeset = Member.validate_owner_exists(changeset, Repo)

        case validated_changeset.valid? do
          true -> Repo.update(validated_changeset)
          false -> {:error, validated_changeset}
        end
    end
  end

  @spec get_user_role(String.t(), String.t()) :: account_role() | nil
  def get_user_role(user_id, account_id) do
    case Repo.get_by(Member, user_id: user_id, account_id: account_id) do
      nil -> nil
      member -> member.role
    end
  end

  @spec user_has_account_access?(String.t(), String.t()) :: boolean()
  def user_has_account_access?(user_id, account_id) do
    Repo.exists?(from m in Member, where: m.user_id == ^user_id and m.account_id == ^account_id)
  end

  # TODO: Add logic when billing implemented
  @spec can_add_user_to_account?(String.t()) :: true
  def can_add_user_to_account?(_account_id) do
    true
  end

  @spec count_account_users(String.t()) :: non_neg_integer()
  def count_account_users(account_id) do
    Repo.aggregate(from(m in Member, where: m.account_id == ^account_id), :count)
  end

  @spec list_user_accounts(String.t()) :: [Account.t()]
  def list_user_accounts(user_id) do
    from(a in Account,
      join: m in Member,
      on: m.account_id == a.id,
      where: m.user_id == ^user_id
    )
    |> Repo.all()
  end

  @spec list_account_users(String.t()) :: [User.t()]
  def list_account_users(account_id) do
    from(u in User,
      join: m in Member,
      on: m.user_id == u.id,
      where: m.account_id == ^account_id
    )
    |> Repo.all()
  end

  @spec list_account_members(String.t()) :: [Member.t()]
  def list_account_members(account_id) do
    from(m in Member,
      where: m.account_id == ^account_id,
      preload: [:user]
    )
    |> Repo.all()
  end

  @spec list_accounts_with_role(String.t(), account_role()) :: [Account.t()]
  def list_accounts_with_role(user_id, role) do
    from(a in Account,
      join: m in Member,
      on: m.account_id == a.id,
      where: m.user_id == ^user_id and m.role == ^role
    )
    |> Repo.all()
  end

  @spec by_user(String.t()) :: Ecto.Query.t()
  def by_user(user_id) do
    from m in Member, where: m.user_id == ^user_id
  end

  @spec by_account(String.t()) :: Ecto.Query.t()
  def by_account(account_id) do
    from m in Member, where: m.account_id == ^account_id
  end

  @spec by_role(account_role()) :: Ecto.Query.t()
  def by_role(role) do
    from m in Member, where: m.role == ^role
  end

  @spec with_user_preloads() :: Ecto.Query.t()
  def with_user_preloads do
    from m in Member, preload: [:user]
  end

  @spec with_account_preloads() :: Ecto.Query.t()
  def with_account_preloads do
    from m in Member, preload: [:account]
  end

  defp count_owners(account_id) do
    Repo.aggregate(
      from(m in Member, where: m.account_id == ^account_id and m.role == :owner),
      :count
    )
  end
end

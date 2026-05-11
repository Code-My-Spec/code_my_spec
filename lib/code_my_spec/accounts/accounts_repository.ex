defmodule CodeMySpec.Accounts.AccountsRepository do
  @moduledoc """
  Data access layer for account entities. Accounts are created
  explicitly during onboarding — there is no auto-provisioned
  "personal" account concept. Every account is owned by at least
  one user via a `members` row.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Accounts.{Account, Member}
  alias CodeMySpec.Repo

  @type account_attrs :: %{
          optional(:name) => String.t(),
          optional(:slug) => String.t()
        }

  ## Basic CRUD Operations

  @spec create_account(attrs :: account_attrs()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_account(id :: integer()) :: Account.t() | nil
  def get_account(id) do
    Repo.get(Account, id)
  end

  @spec get_account!(id :: integer()) :: Account.t()
  def get_account!(id) do
    Repo.get!(Account, id)
  end

  @spec update_account(Account.t(), attrs :: map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_account(Account.t()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def delete_account(%Account{} = account) do
    Repo.delete(account)
  end

  @doc """
  Creates an account and the owning member row in one transaction.
  The single entry point for account creation — every account has
  exactly one owner at birth.
  """
  @spec create_account_with_owner(user_id :: integer(), attrs :: map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_account_with_owner(user_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, account} <- attrs |> Account.create_changeset() |> Repo.insert(),
           {:ok, _member} <-
             create_member(%{user_id: user_id, account_id: account.id, role: :owner}) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  ## Query Builders

  @spec by_slug(slug :: String.t()) :: Ecto.Query.t()
  def by_slug(slug) do
    from(a in Account, where: a.slug == ^slug)
  end

  @spec with_preloads(preloads :: [atom()]) :: Ecto.Query.t()
  def with_preloads(preloads) do
    from(a in Account, preload: ^preloads)
  end

  ## Helper Functions

  defp create_member(attrs) do
    %Member{}
    |> Member.changeset(attrs)
    |> Repo.insert()
  end
end

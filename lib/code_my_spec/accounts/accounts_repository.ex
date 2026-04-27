defmodule CodeMySpec.Accounts.AccountsRepository do
  @moduledoc """
  Data access layer for account entities, handling personal and team account creation,
  basic account operations, and query building within the multi-tenant architecture.
  """

  import Ecto.Query, warn: false
  alias CodeMySpec.Repo
  alias CodeMySpec.Accounts.{Account, Member}
  alias CodeMySpec.Users.User

  @type account_attrs :: %{
          name: String.t(),
          slug: String.t(),
          type: account_type()
        }
  @type account_type :: :personal | :team

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

  ## Account Type Management

  @spec create_personal_account(user_id :: integer()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_personal_account(user_id) do
    user = Repo.get!(User, user_id)
    name = extract_name_from_email(user.email)

    create_personal_account(user_id, %{name: name})
  end

  @spec create_personal_account(user_id :: integer(), attrs :: map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_personal_account(user_id, attrs) when is_map(attrs) do
    attrs_with_type =
      attrs
      |> stringify_keys()
      |> Map.put("type", "personal")

    Repo.transaction(fn ->
      with {:ok, account} <-
             attrs_with_type |> Account.create_changeset() |> Repo.insert(),
           {:ok, _member} <-
             create_member(%{user_id: user_id, account_id: account.id, role: :owner}) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec create_team_account(attrs :: map(), creator_id :: integer()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_team_account(attrs, creator_id) do
    Repo.transaction(fn ->
      with {:ok, account} <- create_account_with_type(attrs, :team),
           {:ok, _member} <-
             create_member(%{user_id: creator_id, account_id: account.id, role: :owner}) do
        account
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec get_personal_account(user_id :: integer()) :: Account.t() | nil
  def get_personal_account(user_id) do
    from(a in Account,
      join: m in Member,
      on: m.account_id == a.id,
      where: m.user_id == ^user_id and a.type == :personal
    )
    |> Repo.one()
  end

  @spec ensure_personal_account(user_id :: integer()) :: Account.t()
  def ensure_personal_account(user_id) do
    case get_personal_account(user_id) do
      nil ->
        {:ok, account} = create_personal_account(user_id)
        account

      account ->
        account
    end
  end

  ## Query Builders

  @spec by_slug(slug :: String.t()) :: Ecto.Query.t()
  def by_slug(slug) do
    from(a in Account, where: a.slug == ^slug)
  end

  @spec by_type(type :: account_type()) :: Ecto.Query.t()
  def by_type(type) do
    from(a in Account, where: a.type == ^type)
  end

  @spec with_preloads(preloads :: [atom()]) :: Ecto.Query.t()
  def with_preloads(preloads) do
    from(a in Account, preload: ^preloads)
  end

  ## Helper Functions

  defp create_account_with_type(attrs, type) do
    %Account{}
    |> Account.changeset(attrs)
    |> Ecto.Changeset.put_change(:type, type)
    |> Repo.insert()
  end

  defp create_member(attrs) do
    %Member{}
    |> Member.changeset(attrs)
    |> Repo.insert()
  end

  defp extract_name_from_email(email) do
    email
    |> String.split("@")
    |> List.first()
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end
end

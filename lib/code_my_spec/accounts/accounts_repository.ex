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

  When the slug is auto-derived from the name (no explicit `:slug`
  in attrs) and that derived slug collides with an existing account,
  the slug is silently suffixed (`acme`, `acme-2`, `acme-3`, …) and
  the insert retried. The user-supplied name is preserved as typed;
  the slug is private addressing and shouldn't burden activation.
  """
  @spec create_account_with_owner(user_id :: integer(), attrs :: map()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_account_with_owner(user_id, attrs) when is_map(attrs) do
    attrs = ensure_available_slug(attrs)

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

  @slug_retry_limit 50

  # If the caller didn't supply a slug, derive one from the name and pick
  # the next available variant (`acme`, `acme-2`, `acme-3`, …). A unique
  # constraint on the column is the safety net — a TOCTOU race here just
  # surfaces as a normal changeset error.
  defp ensure_available_slug(attrs) do
    if user_provided_slug?(attrs) do
      attrs
    else
      case derive_base_slug(attrs) do
        nil -> attrs
        base -> put_attr(attrs, :slug, find_available_slug(base, 0))
      end
    end
  end

  defp user_provided_slug?(%{slug: slug}) when is_binary(slug) and byte_size(slug) > 0, do: true
  defp user_provided_slug?(%{"slug" => slug}) when is_binary(slug) and byte_size(slug) > 0, do: true
  defp user_provided_slug?(_), do: false

  defp derive_base_slug(attrs) do
    case fetch_attr(attrs, :name) do
      name when is_binary(name) and byte_size(name) > 0 ->
        name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]/, "-")
        |> String.replace(~r/-+/, "-")
        |> String.trim("-")

      _ ->
        nil
    end
  end

  defp find_available_slug(base, attempt) when attempt >= @slug_retry_limit, do: base

  defp find_available_slug(base, attempt) do
    candidate = if attempt == 0, do: base, else: "#{base}-#{attempt + 1}"

    if Repo.exists?(from a in Account, where: a.slug == ^candidate) do
      find_available_slug(base, attempt + 1)
    else
      candidate
    end
  end

  defp fetch_attr(attrs, key) do
    case attrs do
      %{^key => value} -> value
      _ -> Map.get(attrs, to_string(key))
    end
  end

  # Match the key style of the input map so Ecto.Changeset.cast doesn't
  # see mixed atom/string keys. Form params come in as `%{"name" => ...}`;
  # fixture/programmatic calls use `%{name: ...}`.
  defp put_attr(attrs, key, value) do
    cond do
      Map.has_key?(attrs, to_string(key)) -> Map.put(attrs, to_string(key), value)
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      string_keyed?(attrs) -> Map.put(attrs, to_string(key), value)
      true -> Map.put(attrs, key, value)
    end
  end

  defp string_keyed?(attrs) do
    Enum.any?(Map.keys(attrs), &is_binary/1)
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

defmodule CodeMySpec.AccountSecrets.AccountSecretRepository do
  @moduledoc """
  Data access for account credential material.

  The mirror of `ProjectSecretRepository` over the same table, deriving the
  owner from `scope.active_account_id` instead of `active_project_id`. Scopes
  with no active account fail the function head rather than falling through to
  an unscoped query.
  """

  import Ecto.Query

  alias CodeMySpec.ProjectSecrets.ProjectSecret
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @spec fetch(Scope.t(), String.t(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def fetch(%Scope{active_account_id: account_id}, key, environment)
      when is_binary(account_id) and is_binary(key) and is_binary(environment) do
    ProjectSecret
    |> where([s], s.account_id == ^account_id and s.key == ^key and s.environment == ^environment)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  @doc """
  Lists the key/environment pairs an account holds — never the values.
  """
  @spec list_keys(Scope.t()) :: [%{key: String.t(), environment: String.t()}]
  def list_keys(%Scope{active_account_id: account_id}) when is_binary(account_id) do
    ProjectSecret
    |> where([s], s.account_id == ^account_id)
    |> order_by([s], asc: s.environment, asc: s.key)
    |> select([s], %{key: s.key, environment: s.environment})
    |> Repo.all()
  end

  @spec put(Scope.t(), String.t(), binary(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, Ecto.Changeset.t()}
  def put(%Scope{active_account_id: account_id} = scope, key, value, environment)
      when is_binary(account_id) and is_binary(key) and is_binary(environment) do
    attrs = %{key: key, value: value, environment: environment}

    case fetch(scope, key, environment) do
      {:ok, existing} -> write(existing, attrs, account_id)
      {:error, :not_found} -> write(%ProjectSecret{}, attrs, account_id)
    end
  end

  @spec delete(Scope.t(), String.t(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def delete(%Scope{active_account_id: account_id} = scope, key, environment)
      when is_binary(account_id) do
    with {:ok, secret} <- fetch(scope, key, environment) do
      Repo.delete(secret)
    end
  end

  @spec exists?(Scope.t(), String.t(), String.t()) :: boolean()
  def exists?(%Scope{active_account_id: account_id}, key, environment)
      when is_binary(account_id) do
    ProjectSecret
    |> where([s], s.account_id == ^account_id and s.key == ^key and s.environment == ^environment)
    |> Repo.exists?()
  end

  defp write(%ProjectSecret{id: nil} = secret, attrs, account_id) do
    secret |> ProjectSecret.account_changeset(attrs, account_id) |> Repo.insert()
  end

  defp write(secret, attrs, account_id) do
    secret |> ProjectSecret.account_changeset(attrs, account_id) |> Repo.update()
  end
end

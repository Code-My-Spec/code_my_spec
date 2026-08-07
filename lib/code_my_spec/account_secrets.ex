defmodule CodeMySpec.AccountSecrets do
  @moduledoc """
  Credential material belonging to an account rather than a project.

  Shares a table and a schema with `CodeMySpec.ProjectSecrets`; only the owner
  column differs. The split is by what the credential *names*, not by who
  happens to be using it:

  - A **Hetzner API token** names one Hetzner account. The servers it can
    reach are shared across every project, and they outlive any of them — a
    box left over from a project that no longer exists still bills. This grain.
  - The **server access key** goes with it, so a box created from
    `/app/servers` is reachable by a deploy run later from any project.
  - **Age private keys** stay on the project. They open that project's SOPS
    environment files and mean nothing outside it.

  ## Resolution order

  Callers that can accept either grain should read the account first and fall
  back to the project — see `CodeMySpec.Provisioning.Hetzner.token/1`. That
  keeps installs working where the token was stored per-project before the
  account grain existed, without the reader having to know which era it is in.

  Everything `ProjectSecrets` says about not letting plaintext reach an agent
  applies unchanged: `value` is encrypted at rest via
  `CodeMySpec.Encrypted.Binary`, and `list_keys/1` returns names only.
  """

  alias CodeMySpec.AccountSecrets.AccountSecretRepository
  alias CodeMySpec.ProjectSecrets.ProjectSecret
  alias CodeMySpec.Users.Scope

  @default_environment "global"

  @doc """
  Fetches an account secret's decrypted value.

  ## Examples

      iex> fetch_value(scope, "hetzner_api_token")
      {:ok, "..."}
  """
  @spec fetch_value(Scope.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found}
  def fetch_value(%Scope{} = scope, key, opts \\ []) do
    with {:ok, %ProjectSecret{value: value}} <-
           AccountSecretRepository.fetch(scope, key, environment(opts)) do
      {:ok, value}
    end
  end

  @doc """
  Stores an account secret, replacing any existing value for the same key
  and environment.
  """
  @spec put_value(Scope.t(), String.t(), binary(), keyword()) ::
          {:ok, ProjectSecret.t()} | {:error, Ecto.Changeset.t()}
  def put_value(%Scope{} = scope, key, value, opts \\ []) do
    AccountSecretRepository.put(scope, key, value, environment(opts))
  end

  @doc """
  Lists the keys an account holds, with their environments — never values.
  """
  @spec list_keys(Scope.t()) :: [%{key: String.t(), environment: String.t()}]
  defdelegate list_keys(scope), to: AccountSecretRepository

  @doc """
  Removes an account secret.
  """
  @spec delete_value(Scope.t(), String.t(), keyword()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def delete_value(%Scope{} = scope, key, opts \\ []) do
    AccountSecretRepository.delete(scope, key, environment(opts))
  end

  @doc """
  Checks whether an account secret is present without decrypting it.
  """
  @spec has_value?(Scope.t(), String.t(), keyword()) :: boolean()
  def has_value?(%Scope{} = scope, key, opts \\ []) do
    AccountSecretRepository.exists?(scope, key, environment(opts))
  end

  defp environment(opts), do: Keyword.get(opts, :environment, @default_environment)
end

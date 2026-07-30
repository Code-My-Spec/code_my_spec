defmodule CodeMySpec.ProjectSecrets do
  @moduledoc """
  Context module for a project's non-OAuth credential material.

  Holds the credentials the provisioning routine needs that cannot be
  OAuth tokens:

  - the Hetzner object-storage key pair — console-only, no Hetzner API
    mints it, and the secret key is unviewable after creation
  - the per-environment age private keys used to decrypt the project's
    SOPS environment files

  OAuth-shaped provider connections belong in `CodeMySpec.Integrations`
  instead, stored as `Integration` rows. The split is by credential
  shape, not by provider: Cloudflare and Resend authenticate via OAuth
  and live there, Hetzner has no OAuth and lives here.

  ## Relationship to the SOPS environment files

  Both this context and the project's committed SOPS files hold secret
  material, and the boundary matters. The SOPS files hold the
  **application's** runtime environment. This context holds the
  credentials the **platform** uses to provision infrastructure and the
  age keys that open those files. One is the payload, the other is the
  keyring.

  ## Why a table and not the process environment

  Decrypted secrets must never reach an agent's process. Keeping this
  material in a scoped table — read explicitly, one key at a time — is
  what makes that enforceable. `list_keys/1` deliberately returns names
  without values so enumeration leaks nothing.

  ## Scoping

  Project-scoped rather than user-scoped, so the same user can hold
  different provider credentials per project, and so a cloud-run agent
  reads credentials without depending on `Provisioning`.
  """

  alias CodeMySpec.ProjectSecrets.{ProjectSecret, ProjectSecretRepository}
  alias CodeMySpec.Users.Scope

  @default_environment "global"

  @doc """
  Fetches a secret's decrypted value.

  Returns the value itself rather than the struct — callers want the
  credential, and handing back a struct invites it into logs.

  ## Examples

      iex> fetch_value(scope, "HETZNER_S3_ACCESS_KEY")
      {:ok, "..."}

      iex> fetch_value(scope, "MISSING")
      {:error, :not_found}
  """
  @spec fetch_value(Scope.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found}
  def fetch_value(%Scope{} = scope, key, opts \\ []) do
    with {:ok, %ProjectSecret{value: value}} <-
           ProjectSecretRepository.fetch(scope, key, environment(opts)) do
      {:ok, value}
    end
  end

  @doc """
  Stores a secret, replacing any existing value for the same key and
  environment.

  Idempotent by design: re-running a setup step converges on the same
  row rather than accumulating duplicates.

  ## Examples

      iex> put_value(scope, "AGE_PRIVATE_KEY", key, environment: "prod")
      {:ok, %ProjectSecret{}}
  """
  @spec put_value(Scope.t(), String.t(), binary(), keyword()) ::
          {:ok, ProjectSecret.t()} | {:error, Ecto.Changeset.t()}
  def put_value(%Scope{} = scope, key, value, opts \\ []) do
    ProjectSecretRepository.put(scope, key, value, environment(opts))
  end

  @doc """
  Lists the keys a project holds, with their environments — never values.

  ## Examples

      iex> list_keys(scope)
      [%{key: "HETZNER_S3_ACCESS_KEY", environment: "global"}]
  """
  @spec list_keys(Scope.t()) :: [%{key: String.t(), environment: String.t()}]
  defdelegate list_keys(scope), to: ProjectSecretRepository

  @doc """
  Removes a secret.

  ## Examples

      iex> delete_value(scope, "RESEND_API_KEY")
      {:ok, %ProjectSecret{}}
  """
  @spec delete_value(Scope.t(), String.t(), keyword()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def delete_value(%Scope{} = scope, key, opts \\ []) do
    ProjectSecretRepository.delete(scope, key, environment(opts))
  end

  @doc """
  Checks whether a secret is present without decrypting it.

  This is what a credential-intake gate should call: it answers "has Sam
  supplied this yet?" without pulling plaintext into the caller.

  ## Examples

      iex> has_value?(scope, "HETZNER_S3_SECRET_KEY")
      true
  """
  @spec has_value?(Scope.t(), String.t(), keyword()) :: boolean()
  def has_value?(%Scope{} = scope, key, opts \\ []) do
    ProjectSecretRepository.exists?(scope, key, environment(opts))
  end

  defp environment(opts), do: Keyword.get(opts, :environment, @default_environment)
end

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

  Callers that can accept either grain should use `fetch_account_then_project/3`,
  which reads the account first and falls back to the project. That keeps
  installs working where a credential was stored per-project before the
  account grain existed, without the reader having to know which era it is in.
  `CodeMySpec.Provisioning.Hetzner.token/1` and `Steps.access_public_key/2` are
  both this: one Hetzner API token, one server SSH key, same precedence.

  Everything `ProjectSecrets` says about not letting plaintext reach an agent
  applies unchanged: `value` is encrypted at rest via
  `CodeMySpec.Encrypted.Binary`, and `list_keys/1` returns names only.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.ProjectSecrets, CodeMySpec.Repo, CodeMySpec.Users],
    exports: :all

  alias CodeMySpec.AccountSecrets.AccountSecretRepository
  alias CodeMySpec.ProjectSecrets
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
  `key`'s value, tried against the account first and the project second.

  The precedence every credential that can live at either grain uses: the
  account holds the current answer, the project is where it lived before the
  account grain existed. Was reimplemented identically in
  `CodeMySpec.Provisioning.Hetzner` and `CodeMySpec.Provisioning.Steps` — same
  eight-line rescue-wrapped lambda twice, for the same reason both needed it:
  `AccountSecretRepository.fetch/3` and `ProjectSecretRepository.fetch/3` both
  fail their function head on a scope with no id bound (deliberately, so an
  unscoped query can never happen by accident — see
  `AccountSecretRepository`'s moduledoc). A scope can reach either module
  before its account or project resolves — a Hetzner call driving cassette
  recording with no project scope at all, a server access key requested while
  scope resolution is still in flight — and that has to read as "no secret
  yet", not crash the caller.

  Never raises. `{:error, :not_found}`, not `:error`, because every other
  fetch in this module answers that on a miss and a caller `case`-ing on this
  alongside a plain `fetch_value/3` should not have to know which one it's
  looking at.
  """
  @spec fetch_account_then_project(Scope.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :not_found}
  def fetch_account_then_project(%Scope{} = scope, key, opts \\ []) do
    with {:error, :not_found} <- safe_fetch(fn -> fetch_value(scope, key, opts) end) do
      safe_fetch(fn -> ProjectSecrets.fetch_value(scope, key, opts) end)
    end
  end

  # A scope with no active account or project fails the repositories' function
  # heads rather than falling through to an unscoped query — deliberately, per
  # `AccountSecretRepository`'s moduledoc. That is the one exception this
  # rescues into `{:error, :not_found}` rather than letting propagate: not a
  # blanket "never crash," a specific, understood boundary.
  defp safe_fetch(read) do
    case read.() do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
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

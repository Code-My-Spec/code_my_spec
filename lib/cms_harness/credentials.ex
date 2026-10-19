defmodule CmsHarness.Credentials do
  @moduledoc """
  Which credential this harness presents for a given working copy.

  A deploy key reaches exactly one project and one harness serves several, so
  the credential is resolved per working copy, like its identity.

  ## Resolution order

    1. The harness's persisted OAuth credential for the target server,
       refreshed before expiry. Refused credentials stop resolution.

    2. `deploy_key` in this working copy's own `.cms_harness.json`, written by
       `mix cms.harness.onboard` (gitignored, `0600`).
    3. `:harness_deploy_key` — machine-wide configuration.

  See knowledge/harness, "Credentials".
  """

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Projects
  alias CmsHarness.ServedRoots

  @type source :: :harness_oauth | :working_copy_key | :configured_deploy_key
  @type result :: {:ok, String.t(), source()} | {:error, term()}

  @doc """
  The credential to present for the working copy at `root`, and where it came
  from.

  The source is returned because a refusal's diagnosis depends on which of the
  three answered.
  """
  @spec for_working_copy(String.t() | nil) :: result()
  def for_working_copy(root) do
    with {:error, :no_credential} <- from_harness_oauth(Config.server_url_for(root)),
         {:error, :no_credential} <- from_working_copy(root) do
      from_configured_deploy_key()
    end
  end

  @doc """
  Any credential this harness holds, for a call that is not about one copy.

  For lookups that have no root yet, such as `WorkingCopies.ask_server/1`
  placing an id this daemon cannot yet find on disk.
  """
  @spec any() :: result()
  def any do
    with {:error, :no_credential} <- from_harness_oauth(Config.server_url()),
         {:error, :no_credential} <- from_any_working_copy() do
      from_configured_deploy_key()
    end
  end

  # The first served checkout's recorded key — where a daemon's credential
  # lives. Served roots and durable hints only, never the cwd (under the suite
  # it is this repo, holding a real key). Hints supply a credential for the
  # boot announce; they never decide what is served.
  defp from_any_working_copy do
    (Projects.list() ++ ServedRoots.list())
    |> Enum.uniq()
    |> Enum.find_value({:error, :no_credential}, fn root ->
      case from_working_copy(root) do
        {:ok, _key, _source} = found -> found
        _ -> nil
      end
    end)
  end

  # Only absence permits project-key fallback; refusal and refresh failures
  # must propagate so revoked authorization cannot silently change identity.
  defp from_harness_oauth(server) do
    opts = Application.get_env(:code_my_spec, CodeMySpec.Auth.HarnessOAuth, [])

    case CodeMySpec.Auth.HarnessOAuth.access_token(server, opts) do
      {:ok, token} -> {:ok, token, :harness_oauth}
      {:error, _reason} = error -> error
    end
  end

  defp from_working_copy(root) when is_binary(root) and root != "" do
    case HarnessConfig.read_file(root) do
      {:ok, %{deploy_key: key}} when is_binary(key) and key != "" ->
        {:ok, key, :working_copy_key}

      _ ->
        {:error, :no_credential}
    end
  end

  defp from_working_copy(_root), do: {:error, :no_credential}

  # Configuration, not the environment. A sprite's key reaches its copy's
  # `.cms_harness.json` through onboarding instead.
  defp from_configured_deploy_key do
    case Config.deploy_key() do
      {:ok, key} -> {:ok, key, :configured_deploy_key}
      {:error, :no_credential} -> {:error, :no_credential}
    end
  end
end

defmodule CmsHarness.Credentials do
  @moduledoc """
  Which credential this harness presents for a given working copy.

  ## Why a harness needs more than one

  Identity is resolved per working copy and credentials were held per daemon,
  and nothing reconciled the two. `ProjectIdentity.resolve/1` runs once per root
  — a developer's harness serves every checkout it has a subtree for — while
  `CMS_DEPLOY_KEY` is a property of whatever launched the process. A deploy key
  reaches exactly one project (`HarnessProjectChannel.authorize_deploy_key/3`,
  and deliberately: a harness on one project should not thereby inherit
  everything its owner can do), so a daemon serving two projects could only ever
  join one of them.

  Measured 2026-08-21: a checkout of `broken_oaths` served by the CodeMySpec
  daemon connected its socket — the key is valid — and had every join refused:

      CONNECTED TO CodeMySpecWeb.UserSocket in 7ms
      REFUSED JOIN harness_project:49760b8b-… in 1µs

  every thirty seconds, with every hook in that checkout answering "channel
  down, server answering 200". It had been invisible until then only because a
  separate bug made that copy claim the *other* project's id, which the key does
  cover — so it joined successfully as the wrong project and wrote 8,374 file
  rows into it.

  ## Resolution order

    1. `CMS_TOKEN` — a user token reaches every project its user can access, so
       one answers for all of them and there is nothing to record per copy.
    2. `deploy_key` in this working copy's own `.cms_harness.json`, written by
       `mix cms.harness.onboard`.
    3. `CMS_DEPLOY_KEY` — the single-project daemon and the sprite, unchanged.

  ## Why it lives in `.cms_harness.json`

  Because that is already the file a working copy says what it is in, and the
  harness already walks up to it (`WorkingCopyWalk`, `HarnessConfig.read_file/1`).
  A credential belongs with the identity it authenticates rather than in a second
  store that has to be kept in step with it — this harness has paid for "two
  sources for one question" twice already, in `CMS_PROJECT_ID` against
  `config.yml` and in `CMS_HARNESS_ID` against this same file.

  Safe there because git never sees it: `.gitignore:103` names
  `.cms_harness.json` and it is untracked. `HarnessConfig.write/2` sets `0600`
  for the accounts git does not govern.

  The alternative built first and dropped was `~/.codemyspec/credentials.json`,
  a central map of project id to key. It works, and it is a new file, a new
  path, a new mix task and a second thing onboarding has to remember to update —
  all to hold what the per-copy file it already writes has room for.
  """

  alias CmsHarness.Config
  alias CmsHarness.HarnessConfig

  @type source :: :user_token | :working_copy_key | :configured_deploy_key
  @type result :: {:ok, String.t(), source()} | {:error, :no_credential}

  @doc """
  The credential to present for the working copy at `root`, and where it came
  from.

  The source is returned rather than kept private because the refusal needs it.
  A join refused as `unauthorized` has one useful diagnosis — the credential
  reaches a different project — and only the caller that knows which of the
  three answered can say what to do about it.
  """
  @spec for_working_copy(String.t() | nil) :: result()
  def for_working_copy(root) do
    with {:error, :no_credential} <- from_user_token(),
         {:error, :no_credential} <- from_working_copy(root) do
      from_configured_deploy_key()
    end
  end

  @doc """
  Any credential this harness holds, for a call that is not about one copy.

  `WorkingCopies.ask_server/1` asks the server where a harness is; the answer
  does not depend on who asks, and demanding a root would make the lookup
  impossible for the case it exists to resolve — an id this daemon cannot yet
  place on disk.
  """
  @spec any() :: result()
  def any do
    with {:error, :no_credential} <- from_user_token() do
      from_configured_deploy_key()
    end
  end

  # Through `Config`, not `System.get_env/1`. Both of these read the environment
  # *and* application config — the second is how a test, and the packaged CLI,
  # supply a credential — and re-reading only the first here silently dropped
  # that half, leaving the whole harness suite with "no credential, so this
  # harness is connected to nothing". One definition of where a credential comes
  # from, not two.
  defp from_user_token do
    case Config.user_token() do
      {:ok, token} -> {:ok, token, :user_token}
      {:error, :no_credential} -> {:error, :no_credential}
    end
  end

  # `read_file/1` rather than `read/1`: this is about *this* root's own answer,
  # and `read/1` falls through to `CMS_HARNESS_ID`, which belongs to the daemon
  # and not to this copy. The same distinction `ProjectIdentity` draws, for the
  # same reason.
  defp from_working_copy(root) when is_binary(root) and root != "" do
    case HarnessConfig.read_file(root) do
      {:ok, %{deploy_key: key}} when is_binary(key) and key != "" ->
        {:ok, key, :working_copy_key}

      _ ->
        {:error, :no_credential}
    end
  end

  defp from_working_copy(_root), do: {:error, :no_credential}

  # Named for where it comes from now, which is configuration rather than the
  # environment. `Config.deploy_key/0` used to read `CMS_DEPLOY_KEY` first; a
  # sprite reaches the same place by a better route, because its entrypoint
  # passes the key to `mix harness.onboard`, which writes it into that copy's
  # own `.cms_harness.json` — where `from_working_copy/1` above finds it,
  # attributed to the copy it actually belongs to.
  defp from_configured_deploy_key do
    case Config.deploy_key() do
      {:ok, key} -> {:ok, key, :configured_deploy_key}
      {:error, :no_credential} -> {:error, :no_credential}
    end
  end
end

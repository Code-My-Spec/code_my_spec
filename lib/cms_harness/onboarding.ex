defmodule CmsHarness.Onboarding do
  @moduledoc """
  Minting a harness id, and the credential resolution behind it.

  Extracted from `Mix.Tasks.Cms.Harness.Onboard`, which calls into this for
  every one of these: a `Mix.Tasks.*` module is only callable from outside
  its own boundary when it is also named under that boundary's own
  namespace for `exports: :all` to actually cover it (confirmed against
  Boundary's own source -- a `classify_to:` override does not do this on
  its own). Living here instead, under `CmsHarness.*`, needs no such
  override: a spex driving story 1013's criterion 916 in process
  (`CodeMySpecSpex.Fixtures`) can call `mint/2` directly.
  """

  alias CmsHarness.Config
  alias CmsHarness.Device
  alias CmsHarness.HarnessConfig
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.Token
  alias CodeMySpec.Auth.HarnessOAuth
  alias CodeMySpec.Projects

  @doc """
  A checkout with no id asks the server for one.

  Waiting for a channel join to mint it cannot work for a copy nobody
  serves yet: the harness learns which copies to serve by looking ids up,
  so a copy with no id would never be served and would never acquire one.

  Public so it can be exercised directly (story 1013, criteria 916-918):
  the credential-resolution question this decides needs a real database
  and a real HTTP round trip to answer honestly, and a spec driving it
  in-process through `mint/2` gets both without a `mix` subprocess
  recompiling this checkout to ask it.
  """
  @spec mint(String.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def mint(root, project_id, opts \\ []) do
    with {:ok, project} <- project_for(root, project_id),
         credential = credential_for_mint(project.id, opts),
         {:ok, token} <- token_for(credential, opts),
         {:ok, %{status: 200, body: %{"harness_id" => id}}} <- post(project, root, token),
         :ok <-
           HarnessConfig.write(root, %{
             working_copy_id: id,
             project_id: project.id,
             deploy_key: credential_key(credential),
             # The id is meaningful only to the server that issued it; a later
             # run reads this back rather than defaulting to its own server.
             server_url: Config.server_url(),
             root: root
           }) do
      if running_under_mix?(), do: Mix.shell().info("Issued a new harness id for #{root}")
      {:ok, id}
    else
      {:error, :no_project_id} ->
        {:error,
         """
         #{root} does not say which project it is.

         Put a `project_id` in .code_my_spec/config.yml. In a fresh worktree the
         submodule is usually just not checked out: `git submodule update --init
         .code_my_spec`.
         """}

      # Named: against a server this machine's database does not back, the
      # truth is "your credential is for another server", not "you have none".
      {:error, {:refused, 401, reason}} ->
        if Config.dev_box?() do
          {:error, dev_box_remedy("The server refused the dev box token: #{reason}")}
        else
          {:error, "Token exchange refused: #{reason}"}
        end

      {:error, :no_credential} ->
        if Config.dev_box?() do
          {:error, dev_box_remedy("No dev box credential was available.")}
        else
          {:error,
           """
           No credential to mint a harness id for #{root} against #{Config.server_url()}.

           Run mix cms.harness.onboard #{root} --server-url #{Config.server_url()}
           to authorize this machine with a device code. Open the verification URL
           it prints and enter the code; no deploy key is needed.
           """}
        end

      other ->
        {:error, "Could not get a harness id for #{root} from the server: #{inspect(other)}"}
    end
  end

  @doc """
  Which project a checkout belongs to.

  `project_id` wins when given; otherwise `.code_my_spec/config.yml`, then an
  existing `.cms_harness.json`. A disagreement is said out loud rather than
  resolved quietly.
  """
  @spec project_for(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def project_for(root, nil), do: ProjectIdentity.resolve(root)

  def project_for(root, project_id) do
    case ProjectIdentity.resolve(root) do
      {:ok, %{id: ^project_id}} = resolved ->
        resolved

      {:ok, %{id: other}} ->
        # Said out loud rather than resolved quietly either way. One of the two
        # is wrong and only the person running this knows which.
        if running_under_mix?() do
          Mix.shell().info([
            :yellow,
            "warning: #{root} says it belongs to project #{other}, and you asked for " <>
              "#{project_id}. Using #{project_id}. If that is wrong, fix " <>
              "`.code_my_spec/config.yml` in that checkout rather than passing the flag.",
            :reset
          ])
        end

        {:ok, %{id: project_id, root: root, working_copy_id: nil}}

      {:error, _reason} ->
        {:ok, %{id: project_id, root: root, working_copy_id: nil}}
    end
  end

  @doc """
  The project's own deploy key, from this machine's database (a local dev
  server and this task share `code_my_spec_dev`). Returned, not exported.
  Best-effort: no database, an unknown project or a blank key leaves
  `CmsHarness.Token` to answer.
  """
  @spec ensure_local_credential(String.t()) :: {:ok, String.t()} | :none
  def ensure_local_credential(project_id) do
    cond do
      Config.dev_box?() ->
        :none

      local_server?(Config.server_url()) ->
        case local_project_deploy_key(project_id) do
          key when is_binary(key) and key != "" -> {:ok, key}
          _ -> :none
        end

      not blank?(System.get_env("CMS_DEPLOY_KEY")) ->
        {:ok, System.get_env("CMS_DEPLOY_KEY")}

      not local_server?(Config.server_url()) ->
        # This database backs only a server on this machine; for a remote
        # project id it can only answer "never heard of it", which says nothing
        # about the credential.
        if running_under_mix?() do
          Mix.shell().info([
            :yellow,
            "Not reading a deploy key from the local database: this is onboarding " <>
              "against #{Config.server_url()}, whose projects are not in it. " <>
              "Device authorization will be offered if no credential exists.",
            :reset
          ])
        end

        :none
    end
  end

  # A key in hand exchanges directly; otherwise fall back to the lookup.
  # `Token.access_token/0` cannot serve this: its credentials are indexed by
  # roots and projects the daemon already serves, and a copy being onboarded
  # is neither.
  defp dev_box_remedy(reason) do
    server = String.trim_trailing(Config.server_url(), "/")
    host = URI.parse(server).host || server

    "#{reason} Add a dev box on #{server}/app/devices and set its token as a network secret for #{host}. Use the bare token, with no 'Bearer ' prefix."
  end

  # An interactive first boot authenticates with the server. It must not start
  # this checkout's database merely to look for a legacy deploy key.
  defp credential_for_mint(project_id, opts) do
    if Keyword.get(opts, :authorize, false) and blank?(System.get_env("CMS_DEPLOY_KEY")) do
      :none
    else
      ensure_local_credential(project_id)
    end
  end

  defp token_for({:ok, key}, _opts), do: Token.access_token_for_key(key)

  defp token_for(:none, opts) do
    case Token.access_token() do
      {:error, reason} when reason in [:no_credential, :authorization_required] ->
        if Keyword.get(opts, :authorize, false) and not Config.dev_box?() do
          authorize_device(opts)
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  defp authorize_device(opts) do
    server = Config.server_url()
    oauth_opts = Application.get_env(:code_my_spec, HarnessOAuth, [])

    with {:ok, grant} <- HarnessOAuth.begin_authorization(server, Device.ensure_id(), oauth_opts) do
      if running_under_mix?() do
        Mix.shell().info(
          "Approve this harness: open #{grant.verification_uri} and enter #{grant.user_code}"
        )
      end

      poll_device(server, grant, oauth_opts, Keyword.get(opts, :sleep, &Process.sleep/1))
    end
  end

  defp poll_device(server, grant, oauth_opts, sleep) do
    sleep.(grant.interval * 1_000)

    case HarnessOAuth.poll(server, grant, oauth_opts) do
      {:ok, token} ->
        {:ok, token}

      {:error, :authorization_pending} ->
        poll_device(server, grant, oauth_opts, sleep)

      {:error, :slow_down} ->
        poll_device(server, %{grant | interval: grant.interval + 5}, oauth_opts, sleep)

      {:error, :unreachable} ->
        poll_device(server, %{grant | interval: grant.interval * 2}, oauth_opts, sleep)

      error ->
        error
    end
  end

  defp credential_key({:ok, key}), do: key
  defp credential_key(:none), do: nil

  @doc """
  Does this machine's database back the server being posted to?

  Host, not the whole URL: the port distinguishes the dev app from the
  packaged one and both read `code_my_spec_dev` on this machine, so a port
  comparison would skip a lookup that is fine.
  """
  @spec local_server?(String.t()) :: boolean()
  def local_server?(url) do
    case URI.parse(url) do
      %URI{host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  @spec blank?(String.t() | nil) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  @doc """
  A project's deploy key, read from this machine's own database.
  """
  @spec local_project_deploy_key(String.t()) :: String.t() | nil
  def local_project_deploy_key(project_id) do
    with :ok <- start_local_repo(),
         %{deploy_key: key} <- Projects.get_project_by_id(project_id) do
      key
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Only `Vault` (to decrypt the column) and `Repo`, never the full
  application: a `mix phx.server` may already hold :4000.
  """
  @spec start_local_repo() :: :ok | {:error, term()}
  def start_local_repo do
    if Application.get_env(:code_my_spec, :env) == :harness do
      {:error, :harness_has_no_local_repo}
    else
      start_configured_local_repo()
    end
  end

  defp start_configured_local_repo do
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:cloak)

    with {:ok, _} <- ensure_started(CodeMySpec.Vault),
         {:ok, _} <- ensure_started(CodeMySpec.Repo) do
      :ok
    end
  end

  defp ensure_started(mod) do
    case mod.start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp post(project, root, token) do
    Req.post(
      url:
        Config.server_url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/api/harnesses"),
      json: %{
        project_id: project.id,
        root: root,
        label: Config.label(root),
        device_id: device_id(token)
      },
      headers: [{"authorization", "Bearer " <> token}] ++ test_sandbox_header(),
      retry: false,
      receive_timeout: to_timeout(second: 15),
      # Keyed on this module, the one actually making the call --
      # `http_clients_are_stubbable_test.exs` checks the calling module's own
      # name against `config/test.exs`, not whichever module happens to
      # invoke it.
      plug: Application.get_env(:code_my_spec, __MODULE__, [])[:plug]
    )
  end

  # Test-only seam (story 1013, criterion 916, product's decision on the
  # question it raised): exists only so a spex's own subprocess mint request
  # joins that test's Ecto Sandbox transaction, the same way the websocket
  # channel's :harness_connect_headers already does. Guarded so a release
  # (where Mix is never loaded) answers [] rather than crashing -- it would
  # never read a test-only env var anyway.
  defp test_sandbox_header do
    if running_under_mix?() and Mix.env() == :test do
      case System.get_env("CMS_TEST_SANDBOX_UA") do
        ua when is_binary(ua) and ua != "" -> [{"user-agent", ua}]
        _ -> []
      end
    else
      []
    end
  end

  # Guarded the same way `CmsHarness.Application.running_under_mix?/0` is:
  # every real caller boots under Mix (a mix task, or a test/spex run), so
  # this never actually answers false -- it exists so a compiled release,
  # which never calls this module at all, could not crash on `Mix.env()`
  # or `Mix.shell()` even if it somehow did.
  defp running_under_mix?, do: Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0)

  # Which machine this checkout is on. The machine's recorded identity
  # (`~/.codemyspec/device.json`), announcing first if it has none.
  # Announcing is idempotent -- it presents the id we hold -- and the
  # credential is already in hand from `mint/2`.
  defp device_id(token) do
    case Application.get_env(:code_my_spec, :onboard_device_id) do
      id when is_binary(id) and id != "" -> id
      # Announce even with an id on file: it presents that id, so a machine the
      # server already knows stays one machine, and one whose first announce
      # never arrived (it records the id before the round trip) gets registered
      # instead of being sent as an id the devices table has never seen.
      _ -> announced_id(token) || CmsHarness.Device.recorded_id()
    end
  end

  # `nil` when the announce could not reach the server. It logs its own warning
  # and the mint below will fail on the same unreachable server a moment later,
  # so there is nothing useful to add here.
  defp announced_id(token) do
    case CmsHarness.Device.announce(%{}, token) do
      {:ok, %{device_id: id}} -> id
      {:error, _reason} -> nil
    end
  end
end

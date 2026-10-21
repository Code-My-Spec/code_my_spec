defmodule CmsHarness.Config do
  @moduledoc """
  Where the harness is pointed and what it calls itself.

  No default for the credential: a harness that quietly runs unauthenticated
  would look exactly like a harness with nothing to do.
  """

  alias CmsHarness.Credentials
  alias CmsHarness.HarnessConfig

  # A runtime read, not `compile_env`: one build serves the release and
  # `just harness`. Localhost when unset (a dev checkout or the test suite).
  @doc "The server this harness points at when nothing overrides it."
  @spec default_server_url() :: String.t()
  def default_server_url,
    do: Application.get_env(:code_my_spec, :harness_default_server_url, "http://localhost:4000")

  @doc """
  Base URL of the CodeMySpec server, e.g. `https://codemyspec.com`.

  Resolved in order of how specific the instruction is:

    0. `:harness_server_url_override` — this call, this target. Set by
       `mix cms.harness.onboard --server-url` and by nothing else; above the
       shell's variable because it is about the root being onboarded.

    1. `CMS_SERVER_URL` — this run, this shell. What `just harness` uses to aim
       a laptop harness at its own dev server.
    2. `:harness_server_url` — this install, for when the harness should differ
       from the rest of the application.
    3. `:base_url` — what this application means by "the server" everywhere else
       (`OAuthClient.get_server_url/0`, the issues client), wired per-env.
    4. `default_server_url/0` — `:harness_default_server_url`, set at runtime.

  Takes no root, so it never reads a checkout's file (the cwd's would be
  ambient); `server_url_for/1` answers per working copy.
  """
  @spec server_url() :: String.t()
  defdelegate server_url(), to: CodeMySpec.Auth.HarnessOAuth

  @doc """
  Where this instance keeps machine-identity state that lives outside any
  checkout — `device.json` today, and anything that needs the same shape
  later.

  `~/.codemyspec` on a laptop. When `CMS_PROJECT_DIR` is set (a workspace or
  sprite), the directory above it: a workspace shares the box's `$HOME` and
  must not present as the box's own device.
  """
  @spec local_state_dir() :: String.t()
  defdelegate local_state_dir, to: CodeMySpec.Paths

  @doc """
  Where this harness generates a project nobody chose a directory for.

  For `CmsHarness.Projects.Generator`, which has nobody to ask. Harness-owned
  space under `local_state_dir/0`, outside any checkout.
  """
  @spec projects_root() :: String.t()
  def projects_root, do: Path.join(local_state_dir(), "projects")

  @doc """
  The credential the socket authenticates with, for a given project.

  A user token when someone is signed in on this machine, otherwise a deploy
  key — this project's if one is recorded, the environment's if not. The
  server's `UserSocket` accepts either, which is why this one function serves
  the socket and does *not* serve the rest: `/mcp/harness` is behind
  `require_oauth_token`, which takes only the first, so everything HTTP goes
  through `CmsHarness.Token` instead.

  Takes a working copy because a deploy key reaches exactly one project, this
  harness serves several, and the copy's own `.cms_harness.json` is where its
  key is recorded. See `CmsHarness.Credentials`.
  """
  @spec credential(String.t() | nil) :: {:ok, String.t()} | {:error, :no_credential}
  def credential(root \\ nil)

  # A rootless caller (`Device.announce/1`: a machine is not a checkout) takes
  # any credential the served copies hold.
  def credential(nil), do: Credentials.any() |> usable(nil)

  def credential(root), do: root |> Credentials.for_working_copy() |> usable(root)

  # A dev box's credential is its box token, which the socket never presents: it
  # connects with the access token that token was traded for (story 1131).
  defp usable({:ok, _token, :dev_box}, root) do
    case CmsHarness.Token.access_token(root) do
      {:ok, access} -> {:ok, access}
      {:error, _reason} = error -> error
    end
  end

  defp usable({:ok, token, _source}, _root), do: {:ok, token}
  defp usable({:error, reason}, _root), do: {:error, reason}

  @doc """
  A signed-in user's own access token, if this machine has one.

  Kept apart from the deploy key because they are not interchangeable: this one
  the server's OAuth pipeline accepts everywhere, and the other has to be
  exchanged first.
  """

  @spec user_token() :: {:ok, String.t()} | {:error, :no_credential}
  def user_token do
    present(Application.get_env(:code_my_spec, :harness_token))
  end

  @doc """
  The project deploy key this harness was given, if any.

  Read from application config (`:harness_deploy_key`). It buys a short-lived
  token from `POST /api/sprite/token` and is never presented to anything else.
  See `CmsHarness.Token`.
  """
  @spec deploy_key() :: {:ok, String.t()} | {:error, :no_credential}
  def deploy_key do
    present(Application.get_env(:code_my_spec, :harness_deploy_key))
  end

  @doc """
  Whether this harness runs as a dev box (story 1131): `:harness_dev_box`, or
  `CMS_DEV_BOX` set, or a device token configured (including `CMS_DEVICE_TOKEN_FILE`). Such a harness signs in as its
  box, by trading the box token for an access token at `POST /api/devices/token`.
  """
  @spec dev_box?() :: boolean()
  def dev_box? do
    Application.get_env(:code_my_spec, :harness_dev_box, false) == true or
      System.get_env("CMS_DEV_BOX") not in [nil, ""] or match?({:ok, _}, device_token())
  end

  @doc """
  The box token this harness was given, if it holds one: `:harness_device_token`,
  else the file `CMS_DEVICE_TOKEN_FILE` names, else `CMS_DEVICE_TOKEN`.

  A Claude Code cloud box holds none: Anthropic's proxy adds the token to requests
  for this server in transit, so the exchange goes out without it.
  """
  @spec device_token() :: {:ok, String.t()} | {:error, :no_credential}
  def device_token do
    with {:error, :no_credential} <-
           present(Application.get_env(:code_my_spec, :harness_device_token)),
         {:error, :no_credential} <- from_token_file(System.get_env("CMS_DEVICE_TOKEN_FILE")) do
      present(System.get_env("CMS_DEVICE_TOKEN"))
    end
  end

  # A token mounted as a file (a Docker box): not in the environment, so not in
  # `docker inspect`.
  defp from_token_file(path) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, contents} -> present(String.trim(contents))
      {:error, _reason} -> {:error, :no_credential}
    end
  end

  defp from_token_file(_path), do: {:error, :no_credential}

  defp present(value) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_), do: {:error, :no_credential}

  @doc """
  The websocket URL for the server's user socket.

  Fails rather than guessing when there is no credential: the join would be
  refused anyway, and "refused" is a much harder failure to read than "you have
  not given me a token".
  """
  @spec socket_url(String.t() | nil) :: {:ok, String.t()} | {:error, :no_credential}
  def socket_url(root \\ nil) do
    with {:ok, token} <- credential(root) do
      url =
        root
        |> server_url_for()
        |> String.replace(~r{^https://}, "wss://")
        |> String.replace(~r{^http://}, "ws://")
        |> String.trim_trailing("/")
        |> Kernel.<>("/socket/websocket?token=#{token}&vsn=2.0.0")

      {:ok, url}
    end
  end

  @doc """
  The server one working copy talks to: the one its `.cms_harness.json` says
  minted it, or `server_url/0` when it records none.

  The copy's record is what actually happened; a copy onboarded against
  another server must join that one.
  """
  @spec server_url_for(String.t() | nil) :: String.t()
  def server_url_for(nil), do: server_url()

  def server_url_for(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{server_url: url}} when is_binary(url) and url != "" -> url
      _ -> server_url()
    end
  end

  @doc """
  Extra headers a working copy's socket connects with. None, unless
  `:harness_connect_headers` names a module answering `headers/1` for a root.

  The test suite is the only thing that names one: it puts a copy's SQL sandbox
  metadata in the `user-agent`, which `CodeMySpecWeb.UserSocket` reads to let
  the channel use that test's own connection. A config value naming a module,
  not a header value, so nothing global changes per test.
  """
  @spec connect_headers(String.t()) :: [{String.t(), String.t()}]
  def connect_headers(root) do
    case Application.get_env(:code_my_spec, :harness_connect_headers) do
      nil -> []
      module -> module.headers(root)
    end
  end

  @doc """
  Whether the server is answering at all.

  Asked only when a hook is already being refused, so the refusal states a
  fact instead of guessing. Two seconds: an agent is waiting on the refusal.
  """
  @spec probe_server() :: {:http, pos_integer()} | {:error, term()}
  def probe_server do
    [url: server_url(), method: :get, retry: false, receive_timeout: 2_000]
    |> Req.new()
    |> Req.request()
    |> case do
      {:ok, %{status: status}} -> {:http, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  How this harness identifies itself when it takes a project's lease.

  The server shows this string to whoever gets refused, so it has to say
  *which* checkout to go and stop — a hostname alone is not enough when one
  machine runs several.
  """
  @spec label(String.t()) :: String.t()
  def label(project_root), do: "the harness at #{project_root} on #{hostname()}"

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "an unknown host"
    end
  end

  @doc """
  The harness endpoint's bound port, as `record_local_port/1` was told it once
  the endpoint started (`CmsHarness.Supervisor`); the configured port before
  that. Recorded here so the channel can report it without depending on the
  web layer that calls it.
  """
  @spec local_port() :: pos_integer() | nil
  def local_port do
    :persistent_term.get({__MODULE__, :local_port}, nil) ||
      get_in(Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint, []), [:http, :port])
  end

  @doc false
  def record_local_port(port) when is_integer(port) and port > 0,
    do: :persistent_term.put({__MODULE__, :local_port}, port)

  def record_local_port(_port), do: :ok

  @doc "Unsets every variable that describes the harness rather than the project."
  @spec scrubbed_env() :: [{String.t(), nil}]
  def scrubbed_env do
    for {name, _} <- System.get_env(), harness_only?(name), do: {name, nil}
  end

  defp harness_only?("MIX_ENV"), do: true
  defp harness_only?("CMS_" <> _), do: true
  defp harness_only?(_), do: false
end

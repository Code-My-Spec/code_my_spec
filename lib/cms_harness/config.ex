defmodule CmsHarness.Config do
  @moduledoc """
  Where the harness is pointed and what it calls itself.

  Environment first, application config second, and no default for the
  credential — a harness that quietly runs unauthenticated would connect to
  nothing and look exactly like a harness with nothing to do.
  """

  alias CmsHarness.Credentials

  # The server this build points at when nothing else says.
  #
  # `compile_env` rather than reading the build environment through Mix: Mix is
  # not bundled in a release, and a build-environment check in `lib/` once
  # shipped to prod and crashed every new OAuth user for days.
  # `test/release_safety_test.exs` guards the whole of `lib/` against that, and
  # scans comments too — so this says it in words rather than in the call it is
  # avoiding. Same intent, expressed in a way that survives being packaged.
  #
  # It defaults to localhost because that is what an unconfigured build is: a
  # checkout on somebody's machine. Every environment with a real server names
  # it, next to the `:base_url` it already sets.
  @default_server_url Application.compile_env(
                        :code_my_spec,
                        :harness_default_server_url,
                        "http://localhost:4000"
                      )

  @doc "The server this build points at when nothing overrides it."
  @spec default_server_url() :: String.t()
  def default_server_url, do: @default_server_url

  @doc """
  Base URL of the CodeMySpec server, e.g. `https://codemyspec.com`.

  Resolved in order of how specific the instruction is:

    1. `CMS_SERVER_URL` — this run, this shell. What `just harness` uses to aim
       a laptop harness at its own dev server.
    2. `:harness_server_url` — this install, for when the harness should differ
       from the rest of the application.
    3. `:base_url` — what this application means by "the server" everywhere else
       (`OAuthClient.get_server_url/0`, the issues client), wired per-env.
    4. `default_server_url/0` — the build environment's own server.

  So a harness built from this repo is pointed correctly without being told, and
  each layer above only exists to say something more specific than the one below
  it.
  """
  @spec server_url() :: String.t()
  def server_url do
    System.get_env("CMS_SERVER_URL") ||
      Application.get_env(:code_my_spec, :harness_server_url) ||
      Application.get_env(:code_my_spec, :base_url) ||
      @default_server_url
  end

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
  def credential(root \\ nil) do
    case Credentials.for_working_copy(root) do
      {:ok, token, _source} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  A signed-in user's own access token, if this machine has one.

  Kept apart from the deploy key because they are not interchangeable: this one
  the server's OAuth pipeline accepts everywhere, and the other has to be
  exchanged first.
  """
  @spec user_token() :: {:ok, String.t()} | {:error, :no_credential}
  def user_token do
    present(System.get_env("CMS_TOKEN") || Application.get_env(:code_my_spec, :harness_token))
  end

  @doc """
  The project deploy key this harness was given, if any.

  The durable credential on a sprite or a container: it comes from the
  environment, buys a short-lived token from `POST /api/sprite/token`, and is
  never presented to anything else. See `CmsHarness.Token`.
  """
  @spec deploy_key() :: {:ok, String.t()} | {:error, :no_credential}
  def deploy_key do
    present(
      System.get_env("CMS_DEPLOY_KEY") || Application.get_env(:code_my_spec, :harness_deploy_key)
    )
  end

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
        server_url()
        |> String.replace(~r{^https://}, "wss://")
        |> String.replace(~r{^http://}, "ws://")
        |> String.trim_trailing("/")
        |> Kernel.<>("/socket/websocket?token=#{token}&vsn=2.0.0")

      {:ok, url}
    end
  end

  @doc """
  Whether the server is answering at all.

  Asked only when a hook is already being refused, to replace a guess with a
  fact. The refusal used to say "the server itself may well be healthy" — a
  hedge, and on the day it mattered it was wrong: the server was returning 500
  and the message sent the reader to look at the harness's socket.

  Two seconds, because this is on the path of a refusal the agent is waiting
  for, and a slow answer about why nothing works is its own failure.
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
  def label(project_root) do
    System.get_env("CMS_HARNESS_LABEL") || "the harness at #{project_root} on #{hostname()}"
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "an unknown host"
    end
  end
end

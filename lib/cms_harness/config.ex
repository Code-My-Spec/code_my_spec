defmodule CmsHarness.Config do
  @moduledoc """
  Where the harness is pointed and what it calls itself.

  Environment first, application config second, and no default for the
  credential — a harness that quietly runs unauthenticated would connect to
  nothing and look exactly like a harness with nothing to do.
  """

  @doc """
  Base URL of the CodeMySpec server, e.g. `https://codemyspec.com`.

  `:base_url` is the last fallback rather than a fourth thing to configure: it
  is already what this application means by "the server" everywhere else
  (`OAuthClient.get_server_url/0`, the issues client), and it is wired per-env
  at compile time — prod_cli to codemyspec.com, dev_sprite to dev. A harness
  built from this repo is therefore pointed correctly without being told, and
  `:harness_server_url` exists for the case where it should differ.
  """
  @spec server_url() :: String.t()
  def server_url do
    System.get_env("CMS_SERVER_URL") ||
      Application.get_env(:code_my_spec, :harness_server_url) ||
      Application.get_env(:code_my_spec, :base_url) ||
      "http://localhost:4000"
  end

  @doc """
  The credential the socket authenticates with.

  A user token when someone is signed in on this machine, a project deploy key
  when it is a sprite. The server's `UserSocket` accepts either, which is why
  this one function serves the socket — and why it does *not* serve the rest.
  `/mcp/harness` is behind `require_oauth_token`, which takes only the first, so
  everything HTTP goes through `CmsHarness.Token.access_token/0` instead.
  """
  @spec credential() :: {:ok, String.t()} | {:error, :no_credential}
  def credential do
    case user_token() do
      {:ok, token} -> {:ok, token}
      {:error, :no_credential} -> deploy_key()
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
  @spec socket_url() :: {:ok, String.t()} | {:error, :no_credential}
  def socket_url do
    with {:ok, token} <- credential() do
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

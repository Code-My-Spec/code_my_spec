defmodule CodeMySpecDesktop.OAuthClients do
  @moduledoc """
  The OAuth clients the desktop app connects integrations with (bb8bc042).

  The cloud app's clients are confidential: their secrets live on our server.
  A desktop install has no server secret to keep, so it uses clients made for
  that, each redirecting to this machine (`http://127.0.0.1:<port>/callback`):

    * Google: a "Desktop app" client. Google documents its secret as not
      confidential, so it is baked into the build (from `GOOGLE_DESKTOP_*`).
    * Cloudflare: a public client (PKCE, no secret) that accepts any loopback
      port on `/callback` and nothing else.
    * Resend: no shared client. Each install registers its own public client
      (RFC 7591) on first connect and keeps it in `resend_client.json`.

  GitHub connects by device flow, which needs no redirect.

  `configure/0` runs at boot and writes `:integration_client_overrides`, which
  `CodeMySpec.Integrations` merges over each provider's own config.
  """

  alias CmsHarness.Config
  alias CodeMySpec.Integrations.Providers.{Cloudflare, Google, Resend}

  require Logger

  @doc "Point Google, Cloudflare and (once registered) Resend at their desktop clients."
  @spec configure() :: :ok
  def configure do
    overrides =
      %{Google => google(), Cloudflare => cloudflare()}
      |> put_resend(stored_resend())

    Application.put_env(:code_my_spec, :integration_client_overrides, overrides)
  end

  @doc "Where every desktop flow returns: this machine, the app's port, `/callback`."
  @spec redirect_uri() :: String.t()
  def redirect_uri do
    port = Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:http][:port]
    "http://127.0.0.1:#{port}/callback"
  end

  @doc """
  The install's Resend client, registered on first use and again if the
  redirect changed (a different PORT).
  """
  @spec ensure_resend() :: {:ok, String.t()} | {:error, term()}
  def ensure_resend do
    current = redirect_uri()

    case stored_resend() do
      %{"client_id" => id, "redirect_uri" => ^current} ->
        {:ok, id}

      _none_or_stale ->
        with {:ok, id} <- register_resend() do
          configure()
          {:ok, id}
        end
    end
  end

  defp google do
    clients = Application.get_env(:code_my_spec, :desktop_oauth_clients, [])

    [
      client_id: clients[:google_client_id],
      client_secret: clients[:google_client_secret],
      redirect_uri: redirect_uri()
    ]
  end

  defp cloudflare do
    clients = Application.get_env(:code_my_spec, :desktop_oauth_clients, [])

    [
      client_id: clients[:cloudflare_client_id],
      client_secret: nil,
      auth_method: nil,
      redirect_uri: redirect_uri()
    ]
  end

  defp put_resend(overrides, %{"client_id" => id, "redirect_uri" => uri}) do
    Map.put(overrides, Resend,
      client_id: id,
      client_secret: nil,
      auth_method: nil,
      redirect_uri: uri
    )
  end

  defp put_resend(overrides, _none), do: overrides

  defp register_resend do
    uri = redirect_uri()

    body = %{
      client_name: "CodeMySpec desktop",
      redirect_uris: [uri],
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"]
    }

    case Req.post("https://api.resend.com/oauth/register", [json: body] ++ req_options()) do
      {:ok, %Req.Response{status: status, body: %{"client_id" => id}}} when status in 200..201 ->
        File.write!(resend_path(), Jason.encode!(%{client_id: id, redirect_uri: uri}))
        File.chmod!(resend_path(), 0o600)
        {:ok, id}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "[Desktop] Resend client registration answered #{status}: #{inspect(body)}"
        )

        {:error, {:unexpected, status}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp stored_resend do
    with {:ok, json} <- File.read(resend_path()),
         {:ok, client} <- Jason.decode(json) do
      client
    else
      _missing -> nil
    end
  end

  defp resend_path, do: Path.join(Config.local_state_dir(), "resend_client.json")

  defp req_options, do: Application.get_env(:code_my_spec, __MODULE__, [])
end

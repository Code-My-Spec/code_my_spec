defmodule Mix.Tasks.Google.Token do
  @shortdoc "Mint Google access+refresh tokens via a local loopback OAuth capture server"

  @moduledoc """
  Runs the Google OAuth authorization-code flow end to end, capturing the
  redirect with a throwaway local Bandit server so the `code` is never
  swallowed by the running app.

  Used to obtain a token for recording the Search Console / Analytics
  cassettes (`test/code_my_spec/google/*`).

  ## One-time setup

  Google only redirects to a *registered* redirect URI. Add this exact URI
  to the OAuth client's "Authorized redirect URIs" in Google Cloud Console
  (APIs & Services → Credentials → your OAuth 2.0 Client):

      http://localhost:4040/oauth2callback

  (Or run with `--port N` and register `http://localhost:N/oauth2callback`.)

  ## Usage

      mix google.token
      mix google.token --port 4040 --write-env

  - `--port` (default 4040): loopback port for the capture server.
  - `--scope`: space-separated scopes. Defaults to read-only Search Console
    + Analytics + email.
  - `--write-env`: append `GOOGLE_REFRESH_TOKEN` to `envs/test.env`.

  The task prints the authorize URL, waits for you to approve in the
  browser, exchanges the returned code, and prints the access + refresh
  tokens. Record cassettes with:

      GOOGLE_RECORD=1 GOOGLE_REFRESH_TOKEN="1//0..." mix test test/code_my_spec/google/
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  @default_scope "email https://www.googleapis.com/auth/webmasters https://www.googleapis.com/auth/analytics.readonly"
  @token_endpoint "https://oauth2.googleapis.com/token"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [port: :integer, scope: :string, write_env: :boolean]
      )

    # Load runtime config (envs/*.env via runtime.exs) and start Req's deps.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:bandit)

    port = opts[:port] || 4040
    scope = opts[:scope] || @default_scope
    redirect_uri = "http://localhost:#{port}/oauth2callback"

    {client_id, client_secret} = credentials!()
    state = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.CapturePlug, parent: self()},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    url = authorize_url(client_id, redirect_uri, scope, state)

    Mix.shell().info("""

    Capture server listening on #{redirect_uri}

    1. Open this URL in your browser (approve the Search Console + Analytics scopes;
       click through the "unverified app" warning if shown):

    #{url}

    2. After you approve, Google redirects back here and the code is captured
       automatically. Waiting...
    """)

    params = await_callback(state)
    Supervisor.stop(server)

    case params do
      {:ok, code} ->
        exchange_and_report(code, client_id, client_secret, redirect_uri, opts)

      {:error, reason} ->
        Mix.raise("OAuth callback returned an error: #{inspect(reason)}")
    end
  end

  defp await_callback(expected_state) do
    receive do
      {:oauth_callback, query} ->
        cond do
          query["error"] -> {:error, query["error"]}
          query["state"] != expected_state -> {:error, {:state_mismatch, query["state"]}}
          query["code"] -> {:ok, query["code"]}
          true -> {:error, :no_code}
        end
    after
      300_000 -> Mix.raise("Timed out after 5 minutes waiting for the OAuth callback.")
    end
  end

  defp exchange_and_report(code, client_id, client_secret, redirect_uri, opts) do
    form = %{
      client_id: client_id,
      client_secret: client_secret,
      code: code,
      grant_type: "authorization_code",
      redirect_uri: redirect_uri
    }

    case Req.post(@token_endpoint, form: form) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        report(body, opts)

      {:ok, %Req.Response{status: status, body: body}} ->
        Mix.raise("Token exchange failed (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        Mix.raise("Token exchange request failed: #{inspect(reason)}")
    end
  end

  defp report(body, opts) do
    access = body["access_token"]
    refresh = body["refresh_token"]
    expires = body["expires_in"]
    granted = body["scope"]

    Mix.shell().info("""

    ✅ Success.

    access_token  (expires in #{expires}s):
    #{access}

    refresh_token (long-lived#{if refresh, do: "", else: " — NOT returned; re-run with prompt=consent"}):
    #{refresh || "<none>"}

    granted scope:
    #{granted}

    Record cassettes with:
        GOOGLE_RECORD=1 GOOGLE_REFRESH_TOKEN="#{refresh}" mix test test/code_my_spec/google/
    """)

    if opts[:write_env] && refresh, do: write_env(refresh)
  end

  defp write_env(refresh) do
    path = "envs/test.env"
    line = "GOOGLE_REFRESH_TOKEN=#{refresh}"

    existing = if File.exists?(path), do: File.read!(path), else: ""

    kept =
      existing
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "GOOGLE_REFRESH_TOKEN="))
      |> Enum.reject(&(&1 == ""))

    File.write!(path, Enum.join(kept ++ [line], "\n") <> "\n")
    Mix.shell().info("Wrote GOOGLE_REFRESH_TOKEN to #{path}")
  end

  defp authorize_url(client_id, redirect_uri, scope, state) do
    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scope,
        "access_type" => "offline",
        "prompt" => "consent",
        "include_granted_scopes" => "true",
        "state" => state
      })

    "https://accounts.google.com/o/oauth2/v2/auth?" <> query
  end

  defp credentials! do
    client_id =
      Application.get_env(:code_my_spec, :google_client_id) || System.get_env("GOOGLE_CLIENT_ID")

    client_secret =
      Application.get_env(:code_my_spec, :google_client_secret) ||
        System.get_env("GOOGLE_CLIENT_SECRET")

    if is_nil(client_id) or is_nil(client_secret) do
      Mix.raise("GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET not set (check envs/.env).")
    end

    {client_id, client_secret}
  end

  defmodule CapturePlug do
    @moduledoc false
    use Boundary, classify_to: CodeMySpec
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)

      if conn.query_params["code"] || conn.query_params["error"] do
        send(opts[:parent], {:oauth_callback, conn.query_params})

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, """
        <html><body style="font-family: system-ui; padding: 3rem">
        <h1>✅ Authorization captured</h1>
        <p>You can close this tab and return to the terminal.</p>
        </body></html>
        """)
      else
        send_resp(conn, 404, "no code")
      end
    end
  end
end

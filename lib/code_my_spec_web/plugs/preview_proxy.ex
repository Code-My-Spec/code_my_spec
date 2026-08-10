defmodule CodeMySpecWeb.Plugs.PreviewProxy do
  @moduledoc """
  Serves a project's running app from a subdomain of our own domain.

  `preview-{project_id}.codemyspec.com` forwards to whatever port that
  project's instance is on. The subdomain is the whole point rather than a
  convenience: a preview is shown in a frame, and a genuinely third-party
  origin has its cookies blocked by Safari by default — which takes the target
  app's session with it, and with the session goes its CSRF token and its
  LiveView connect. Same-site keeps `SameSite=Lax` working, so the app behaves
  in the frame exactly as it does in a tab.

  Stable per project and open to anyone holding the address: a link Sam sends
  someone keeps working, and they do not need an account to open it.

  This handles ordinary requests. The LiveView socket needs an upgrade pipe and
  is not here yet, so a framed app renders and does not yet come alive.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.WorkspacesRepository

  require Logger

  @prefix "preview-"

  # Hop-by-hop headers belong to one connection and must not be relayed. Passing
  # a stale content-length or a chunked transfer-encoding to the client
  # describes a body we did not send.
  @strip_request ~w(host connection keep-alive transfer-encoding upgrade)
  @strip_response ~w(connection keep-alive transfer-encoding upgrade content-length)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{host: host} = conn, _opts) do
    case project_id(host) do
      nil -> conn
      project_id -> serve(conn, project_id)
    end
  end

  @doc "The address a project's preview is always at."
  @spec host_for(String.t(), String.t()) :: String.t()
  def host_for(project_id, base_host), do: "#{@prefix}#{project_id}.#{base_host}"

  # Only the first label, and only when it carries the prefix. A project id is
  # a UUID, so anything else in that position is not ours to serve.
  defp project_id(host) do
    with [@prefix <> id | _] <- String.split(host, "."),
         {:ok, _} <- Ecto.UUID.cast(id) do
      id
    else
      _ -> nil
    end
  end

  defp serve(conn, project_id) do
    case WorkspacesRepository.get_by_project(project_id) do
      nil ->
        halt_with(conn, 404, "No preview for this project.")

      workspace ->
        forward(conn, workspace)
    end
  end

  # The state is asked for, not guessed from whether the request succeeds: a
  # booting instance and a crashed one both fail to answer, and telling those
  # apart is the reason the pane knows what it knows.
  defp forward(conn, workspace) do
    case Workspaces.state(workspace) do
      state when state in [:running, :broken] ->
        relay(conn, workspace)

      :starting ->
        halt_with(conn, 503, "This app is still starting.")

      :down ->
        halt_with(conn, 502, "This app is not running.")
    end
  end

  defp relay(conn, workspace) do
    if websocket?(conn), do: relay_socket(conn, workspace), else: relay_http(conn, workspace)
  end

  # LiveView's socket. Without it the app renders once and never connects,
  # which looks like a screenshot of a working application — fine until Sam
  # clicks something.
  defp relay_socket(conn, workspace) do
    upstream = Workspaces.url(workspace) <> conn.request_path <> query(conn)

    conn
    |> WebSockAdapter.upgrade(
      CodeMySpecWeb.PreviewSocket,
      {upstream, conn.req_headers},
      timeout: 60_000
    )
    |> halt()
  end

  defp websocket?(conn) do
    connection = get_req_header(conn, "connection") |> Enum.join(",") |> String.downcase()
    upgrade = get_req_header(conn, "upgrade") |> Enum.join(",") |> String.downcase()

    String.contains?(connection, "upgrade") and String.contains?(upgrade, "websocket")
  end

  defp relay_http(conn, workspace) do
    {:ok, body, conn} = read_body(conn)
    url = Workspaces.url(workspace) <> conn.request_path <> query(conn)

    case request(conn, url, body) do
      {:ok, response} ->
        conn
        |> put_response_headers(response.headers)
        |> allow_framing()
        |> send_resp(response.status, response.body)
        |> halt()

      {:error, reason} ->
        Logger.warning("[PreviewProxy] #{url} did not answer: #{inspect(reason)}")
        halt_with(conn, 502, "This app stopped answering.")
    end
  end

  defp request(conn, url, body) do
    Req.request(
      method: conn.method |> String.downcase() |> String.to_existing_atom(),
      url: url,
      headers: Enum.reject(conn.req_headers, fn {k, _} -> k in @strip_request end),
      body: body,
      decode_body: false,
      redirect: false,
      retry: false,
      receive_timeout: 30_000
    )
  end

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: q}), do: "?" <> q

  defp put_response_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, values}, acc ->
      key = String.downcase(key)

      if key in @strip_response or key == "x-frame-options" do
        acc
      else
        Enum.reduce(List.wrap(values), acc, &put_resp_header(&2, key, &1))
      end
    end)
  end

  # X-Frame-Options is dropped above rather than overwritten: it has no syntax
  # for "this one origin", so leaving any value refuses our frame. frame-ancestors
  # replaces it and says exactly who may embed this.
  defp allow_framing(conn) do
    put_resp_header(conn, "content-security-policy", "frame-ancestors #{ancestors()}")
  end

  defp ancestors do
    Application.get_env(:code_my_spec, __MODULE__, [])[:frame_ancestors] ||
      CodeMySpec.PublicUrl.base()
  end

  defp halt_with(conn, status, message) do
    conn
    |> allow_framing()
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end

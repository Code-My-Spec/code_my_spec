defmodule CodeMySpecSpex.PreviewSessionApp do
  @moduledoc "A small Phoenix app served at the preview frame's host for session contract specs."

  def embedder_host do
    CodeMySpec.Workspaces.PreviewTunnel.embedder()
    |> URI.parse()
    |> Map.fetch!(:host)
  end

  def configure do
    endpoint = CodeMySpecSpex.PreviewSessionApp.Endpoint
    previous = Application.get_env(:code_my_spec, endpoint)

    Application.put_env(:code_my_spec, endpoint,
      server: false,
      secret_key_base: String.duplicate("preview_session_test_secret", 4),
      pubsub_server: CodeMySpec.PubSub,
      live_view: [signing_salt: "preview-session-test"]
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:code_my_spec, endpoint, previous),
        else: Application.delete_env(:code_my_spec, endpoint)
    end)

    :ok
  end
end

defmodule CodeMySpecSpex.PreviewSessionApp.CounterLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, count: 0, session_id: session["preview_id"])}
  end

  @impl true
  def handle_event("save", _params, socket) do
    {:noreply, update(socket, :count, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="session">{@session_id}</div>
    <form phx-submit="save"><button type="submit">Save</button></form>
    <div id="count">{@count}</div>
    """
  end
end

defmodule CodeMySpecSpex.PreviewSessionApp.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Plug.Conn

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:ensure_session)
    plug(:allow_embedding)
  end

  scope "/" do
    pipe_through(:browser)
    live("/", CodeMySpecSpex.PreviewSessionApp.CounterLive)
  end

  defp ensure_session(conn, _) do
    case get_session(conn, :preview_id) do
      nil -> put_session(conn, :preview_id, "sam-preview")
      _ -> conn
    end
  end

  defp allow_embedding(conn, _) do
    put_resp_header(conn, "content-security-policy", "frame-ancestors https://codemyspec.com")
  end
end

defmodule CodeMySpecSpex.PreviewSessionApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :code_my_spec

  @session_options [
    store: :cookie,
    key: "_preview_app_session",
    signing_salt: "preview-session-test",
    same_site: "Lax",
    secure: true
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Session, @session_options)
  plug(CodeMySpecSpex.PreviewSessionApp.Router)
end

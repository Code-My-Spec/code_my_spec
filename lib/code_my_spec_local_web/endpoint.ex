defmodule CodeMySpecLocalWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :code_my_spec

  # Session must be defined before the LiveView socket (provides @session_options)
  @session_options [
    store: :cookie,
    key: "_local_key",
    signing_salt: "local_dev"
  ]

  # LiveView websocket
  socket "/local-live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  # Data-plane socket the Pi harness connects to (see CodeMySpec.AgentHarness).
  socket "/harness_socket", CodeMySpecLocalWeb.HarnessSocket,
    websocket: true,
    longpoll: false

  # Serve static assets (JS bundle for LiveView)
  plug Plug.Static,
    at: "/local/assets",
    from: {:code_my_spec, "priv/static/local/assets"},
    gzip: false

  # Code reloading in dev
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  # log: :debug demotes "GET /foo" + "Sent 200 in Xms" to debug — dev still
  # shows them, prod_cli (:info) drops them. Keeps the structured log focused
  # on app events, not request boilerplate.
  plug Plug.Telemetry, event_prefix: [:phoenix, :local_endpoint], log: :debug

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Session, @session_options
  plug Plug.Head
  plug CodeMySpecLocalWeb.Router
end

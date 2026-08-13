defmodule CodeMySpecWeb.PreviewListener do
  @moduledoc """
  Serves preview traffic from a listener of its own, because the main endpoint
  cannot serve it.

  `CodeMySpecWeb.Endpoint` declares `socket("/live", Phoenix.LiveView.Socket)`,
  and Phoenix dispatches socket routes before the plug pipeline — so a
  WebSocket request for `/live/websocket` is answered by *our* LiveView socket
  and never reaches `PreviewProxy`, whatever host it carried. A generated
  Phoenix app puts its LiveView socket at exactly that path.

  The failure is quiet and looks like the app's fault. The browser's handshake
  succeeds, so nothing errors; it is talking to the wrong server, its join is
  refused, and LiveView retries forever. The pane shows an app that rendered
  once and never came alive — precisely the failure `PreviewSocket` was
  written to prevent.

  Moving the plug earlier does not help: socket dispatch happens in the
  endpoint's generated `call/2` ahead of any plug. Renaming the generated
  app's socket path would work and is worse — it makes every generated app
  diverge from stock Phoenix to accommodate our proxy, and the point of the
  preview is that the app behaves in the pane exactly as it does in a tab.

  So previews get a listener with no socket routes to collide with. Route
  `preview-*` to this port at the edge; everything else keeps going to the
  endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodeMySpecWeb.Plugs.PreviewProxy

  @impl true
  def init(opts), do: PreviewProxy.init(opts)

  @impl true
  def call(conn, opts) do
    conn
    |> PreviewProxy.call(opts)
    |> not_a_preview()
  end

  # The proxy passes a host through when it is not a preview. On the main
  # endpoint that is correct — the rest of the pipeline handles it. Here there
  # is no rest of the pipeline, and answering with our own site on a preview
  # port would be a confusing thing to hand back.
  defp not_a_preview(%Plug.Conn{halted: true} = conn), do: conn

  defp not_a_preview(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not a preview address.")
    |> halt()
  end

  @doc """
  A child spec for the preview listener, or nothing when no port is set.

  Off unless configured, so a machine that is not serving previews does not
  bind a port for them.
  """
  @spec child_spec_for_config() :: [Supervisor.child_spec()]
  def child_spec_for_config do
    listener(port())
  end

  # `CMS_PREVIEW_PORT` wins over config, because config is per-checkout and the
  # collision is per-machine: every worktree reads the same `config/dev.exs` and
  # so picks the same port, which means a second dev server cannot boot beside
  # :4000 at all — it dies on :eaddrinuse before serving anything. That blocked
  # an agent from testing a live path in a browser, which is not a cost this
  # listener should be imposing on anyone. `0` asks the OS for a free port.
  #
  # Read from the process environment rather than `envs/.env`: Dotenvy loads
  # that file into config, never into `System.get_env`, so it has to be exported
  # on the command line — `CMS_PREVIEW_PORT=4011 mix phx.server`.
  defp port do
    case System.get_env("CMS_PREVIEW_PORT") do
      nil -> configured_port()
      "" -> configured_port()
      value -> parsed_port(Integer.parse(value), value)
    end
  end

  defp configured_port do
    :code_my_spec
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:port)
  end

  defp parsed_port({port, ""}, _value), do: port

  # Loudly, rather than silently falling back to the port it collides with —
  # a typo'd override that quietly serves on 4010 is the failure this exists to
  # prevent, wearing a different hat.
  defp parsed_port(_, value),
    do: raise(ArgumentError, "CMS_PREVIEW_PORT must be a port number, got: #{inspect(value)}")

  defp listener(nil), do: []

  defp listener(port) when is_integer(port),
    do: [{Bandit, plug: __MODULE__, port: port, scheme: :http}]
end

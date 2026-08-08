defmodule CmsHarness.Web.Endpoint do
  @moduledoc """
  The one endpoint, serving the hook routes and nothing else.

  No static files, no session, no LiveView socket, no CSRF — none of which has
  a caller here. What it does have is a JSON body parser and a router, because
  the entire surface is `curl -X POST --data-binary @-` from a Claude Code hook.

  Bound to loopback. These requests come from a process on this machine; there
  is no reason for the port to be reachable from anywhere else, and a harness
  that accepted hook posts from the network would be accepting instructions
  about a working copy from a stranger.
  """

  use Phoenix.Endpoint, otp_app: :code_my_spec

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(CmsHarness.Web.Router)
end

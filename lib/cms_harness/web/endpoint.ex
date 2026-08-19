defmodule CmsHarness.Web.Endpoint do
  @moduledoc """
  The one endpoint, serving the hook routes and nothing else.

  No static files, no session, no LiveView socket, no CSRF — none of which has
  a caller here. What it does have is a body parser and a router.

  Bound to loopback. These requests come from a process on this machine; there
  is no reason for the port to be reachable from anywhere else, and a harness
  that accepted hook posts from the network would be accepting instructions
  about a working copy from a stranger.
  """

  use Phoenix.Endpoint, otp_app: :code_my_spec

  # `:urlencoded` alongside `:json` for `4396345b`: every `skills/*/skill.md`
  # posts `--data-urlencode`, not JSON — the shape a `curl` one-liner in a
  # skill's inline bash can build correctly without hand-escaping `arguments`
  # into a JSON string. Everything else here really is `--data-binary @-`
  # from a hook, which is JSON because Claude Code hands it that already; this
  # widens what the endpoint accepts rather than narrowing what a caller can
  # send, so nothing existing changes shape.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(CmsHarness.Web.Router)
end

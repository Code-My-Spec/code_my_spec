defmodule CmsHarness.Web.Router do
  @moduledoc """
  The hook surface, at the same paths the plugin already posts to.

  The plugin's `hooks.json` hardcodes `http://localhost:PORT/api/hooks/<name>`
  with an `X-Working-Dir` header. Keeping those paths means the harness is a
  drop-in for the local application's endpoint rather than a plugin change
  landing at the same time as an architecture change.
  """

  use Phoenix.Router

  pipeline :hook do
    plug(:accepts, ["json"])
  end

  scope "/api/hooks", CmsHarness.Web do
    pipe_through(:hook)

    post("/session-start", HooksController, :handle)
    post("/pre-tool-use", HooksController, :handle)
    post("/post-tool-use", HooksController, :handle)
    post("/stop", HooksController, :handle)
    post("/subagent-start", HooksController, :handle)
    post("/subagent-stop", HooksController, :handle)
    post("/notification", HooksController, :handle)
    post("/ask-user-question", HooksController, :handle)
  end

  # `PermissionRequest` is not one of the hooks above and does not go through
  # the project channel. It is a question for a person, answered on their phone
  # minutes later, and it blocks the agent until it is. See `PermissionController`.
  scope "/api", CmsHarness.Web do
    pipe_through(:hook)

    post("/permissions/request", PermissionController, :create)
  end

  # The MCP surface, forwarded to the server — see `McpController`. Same URL
  # shape the plugin already uses for the heavy harness
  # (`/mcp?dir=${CLAUDE_PROJECT_DIR}`), so swapping one for the other is a port
  # number and nothing else.
  #
  # `match :*` because streamable HTTP is three methods on one path: POST sends
  # a message, GET opens the server→client stream, DELETE ends the session.
  pipeline :mcp do
    plug(:accepts, ["json", "sse"])
  end

  scope "/", CmsHarness.Web do
    pipe_through(:mcp)

    match(:*, "/mcp", McpController, :proxy)
  end

  # Where a sprite's agent points ANTHROPIC_BASE_URL. Anthropic-shaped on
  # purpose: the agent is an ordinary client that happens to be observed.
  scope "/v1", CmsHarness.Web do
    pipe_through(:hook)

    post("/messages", MessagesController, :create)
  end

  scope "/", CmsHarness.Web do
    # Says whether the harness is up *and* what it can reach, because "up" on
    # its own is the answer that misled people last time.
    get("/health", HealthController, :index)
  end
end

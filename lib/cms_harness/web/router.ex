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

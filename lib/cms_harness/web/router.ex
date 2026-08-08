defmodule CmsHarness.Web.Router do
  @moduledoc """
  The hook surface, addressed by harness id.

  Every request names the working copy it is about, in the path:
  `/api/harnesses/<harness_id>/hooks/<name>`. Onboarding writes that id into
  the plugin's `hooks.json`, so the address is fixed before the agent starts
  and nothing is resolved at request time.

  There is no directory anywhere in here, and that is the point rather than an
  omission. Resolving a hook from the directory it fired in answered
  differently depending on which subdirectory it came from, resolved a nested
  checkout to the outer one, and could not distinguish two copies at the same
  path on different machines — which is exactly the case a worktree, a sprite
  and another laptop are all instances of. The id abstracts that away; a
  directory cannot.
  """

  use Phoenix.Router

  pipeline :hook do
    plug(:accepts, ["json"])
  end

  # The id-addressed surface. Onboarding writes the harness id into the URL in
  # the plugin's hook config, so a request identifies itself by where it is
  # sent rather than by anything the agent interpolates into it — which is what
  # lets one hook config shape serve Claude Code, Codex and Antigravity alike.
  #
  # `hook_name/1` still reads the last path segment, so these are the same
  # actions with the same names one segment deeper.
  scope "/api/harnesses/:harness_id/hooks", CmsHarness.Web do
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

  # There is no unaddressed hook surface. A request that does not name a
  # working copy has no answer here — the directory it fired in is not one, and
  # accepting it as one is what this replaced.
  scope "/api/hooks", CmsHarness.Web do
    pipe_through(:hook)

    post("/*any", HooksController, :handle)
  end

  # `PermissionRequest` is not one of the hooks above and does not go through
  # the project channel. It is a question for a person, answered on their phone
  # minutes later, and it blocks the agent until it is. See `PermissionController`.
  scope "/api", CmsHarness.Web do
    pipe_through(:hook)

    post("/permissions/request", PermissionController, :create)
  end

  # The MCP surface, forwarded to the server — see `McpController`. Addressed
  # the same way the hooks are, as `/mcp?harness=<id>`: two checkouts of one
  # project are two working copies, and sharing an MCP session between them
  # while their hooks stayed apart would be a mismatch nobody could see.
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

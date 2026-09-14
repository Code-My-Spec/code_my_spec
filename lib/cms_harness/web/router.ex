defmodule CmsHarness.Web.Router do
  @moduledoc """
  The hook surface, addressed by harness id.

  Every request names the working copy it is about, in the path:
  `/api/harnesses/<working_copy_id>/hooks/<name>`. Onboarding writes that id into
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

    # Which working copy this request is about, resolved once for every surface
    # below. Hooks, skills and analysis each used to answer that separately and
    # slightly differently. See `ResolveWorkingCopy`; it assigns what it found,
    # including why it found nothing, and each controller refuses in its own
    # voice.
    plug(CmsHarness.Web.ResolveWorkingCopy)
  end

  # The id-addressed surface. Onboarding writes the harness id into the URL in
  # the plugin's hook config, so a request identifies itself by where it is
  # sent rather than by anything the agent interpolates into it — which is what
  # lets one hook config shape serve Claude Code, Codex and Antigravity alike.
  #
  # `hook_name/1` still reads the last path segment, so these are the same
  # actions with the same names one segment deeper.
  scope "/api/harnesses/:working_copy_id/hooks", CmsHarness.Web do
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

  # The agent's own `mix test`, rewritten into a curl by the PreToolUse hook.
  # Addressed like the hooks are, so the run is attributed to the working copy
  # the agent is editing rather than to whatever directory curl happened to run
  # in. See `AnalysisController`.
  scope "/api/harnesses/:harness_id", CmsHarness.Web do
    pipe_through(:hook)

    post("/analysis/run", AnalysisController, :run)

    # Blocks until the analyzers are idle. Fired in the background by an agent
    # that wants to stop against fresh results — see `AnalysisController.wait/2`
    # for why this is HTTP and not an MCP tool.
    post("/analysis/wait", AnalysisController, :wait)

    # Promotion's external door. Blocks for the whole promotion — gate, merge,
    # `just restart` — which is minutes on a cold tree, and that is why it is
    # here rather than an MCP tool: the same 30s cap that made `analysis/wait`
    # an endpoint refuses this workload too. See `PromotionController`.
    #
    # There is no `/promotion/wait` beside it. Analysis has one because the
    # server drives a queue that has an idle state to wait for; a promotion is
    # one act with no ledger and nothing to rejoin, so `run` *is* the wait URL
    # and a second path would be a second way to do one thing.
    post("/promotion/run", PromotionController, :run)

    # `4396345b`: the surface every `skills/*/skill.md` posts to. Addressed the
    # same way analysis and hooks are — see `SkillsController`.
    post("/skills/start", SkillsController, :start)

    # Drop this copy's channel and take it up again — the reconnect a harness
    # restart performs, for one root rather than all of them. `handle_join/3` is
    # where the `agents_to_restore` handshake runs, and one process serving
    # every checkout meant observing it cost four other projects their in-flight
    # work (`0fb7bf03`). See `RejoinController`.
    post("/rejoin", RejoinController, :run)
  end

  # Skills, unaddressed.
  #
  # There used to be nothing here, on the reasoning that "a request that does
  # not name a working copy has no answer" — true while the client was the only
  # thing that could resolve one. Every `skill.md` therefore grepped
  # `.cms_harness.json` itself and sent `${HID:-unonboarded}` when it could not,
  # which is a sentinel this server had to special-case.
  #
  # `ResolveWorkingCopy` answers it now, from `X-Working-Dir`, and refuses by
  # naming the directory to onboard rather than explaining a shell fallback the
  # reader never saw. The addressed route above still works and still wins.
  scope "/api", CmsHarness.Web do
    pipe_through(:hook)

    post("/skills/start", SkillsController, :start)
  end

  # There is no unaddressed hook surface *by path*: a hook says where it fired
  # in its own payload, which this catch-all resolves the same way.
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
  # the same way the hooks are, now literally: `/api/harnesses/<id>/mcp`. Two
  # checkouts of one
  # project are two working copies, and sharing an MCP session between them
  # while their hooks stayed apart would be a mismatch nobody could see.
  #
  # `match :*` because streamable HTTP is three methods on one path: POST sends
  # a message, GET opens the server→client stream, DELETE ends the session.
  pipeline :mcp do
    plug(:accepts, ["json", "sse"])
  end

  scope "/api/harnesses/:harness_id", CmsHarness.Web do
    pipe_through(:mcp)

    match(:*, "/mcp", McpController, :proxy)
  end

  # The query form, kept because the released marketplace plugin sends it and
  # removing it would refuse MCP on every machine running that release. It is
  # the older spelling of the same address, not a second mechanism — both land
  # in the same controller and resolve the same id.
  scope "/", CmsHarness.Web do
    pipe_through(:mcp)

    match(:*, "/mcp", McpController, :proxy)
  end

  # Where an agent points ANTHROPIC_BASE_URL. Anthropic-shaped on purpose: the
  # agent is an ordinary client that happens to be observed.
  #
  # Addressed like the hooks and the MCP surface, and for the same reason. A
  # model turn has exactly their question — which working copy is this? — and
  # was the last surface with no way to answer it. It guessed instead, by
  # counting projects and taking the answer only when there was one, which on
  # any machine serving more than one working copy is never. Every turn was
  # forwarded correctly and then dropped on the floor with a warning nobody
  # reads, which looks identical to an agent that never ran.
  scope "/api/harnesses/:working_copy_id/v1", CmsHarness.Web do
    pipe_through(:hook)

    post("/messages", MessagesController, :create)
  end

  # The unaddressed spelling, kept because sprites in the field point at it and
  # removing it would stop their turns reaching Anthropic at all. It still
  # records when the harness serves exactly one working copy, which is a
  # sprite's whole shape — see `MessagesController.served_root/0`.
  scope "/v1", CmsHarness.Web do
    pipe_through(:hook)

    post("/messages", MessagesController, :create)
  end

  scope "/", CmsHarness.Web do
    # Says whether the harness is up *and* what it can reach, because "up" on
    # its own is the answer that misled people last time.
    get("/health", HealthController, :index)

    # What every project's analyzer queue actually believes right now, plus
    # machine-wide slot usage and load — for the dev dashboard. Unaddressed
    # for the same reason `/health` is: it reports on everything this
    # harness holds, not one working copy.
    get("/dashboard-status", DashboardStatusController, :index)
  end
end

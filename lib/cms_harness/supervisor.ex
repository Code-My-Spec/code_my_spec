defmodule CmsHarness.Supervisor do
  @moduledoc """
  The harness's supervision tree.

  Built up from nothing rather than copied from the full local application and
  trimmed. That application boots sixteen children; what survives a deletion
  pass is whatever nobody was sure about, which is how it ends up heavy again.
  Every child below is here because something demonstrably does not work
  without it, and the justification is written next to it.

  Notably absent, and each absence is a decision:

    * **No Repo, no Vault, no migrator.** The harness holds no database. It
      talks to the server for Files, leases, and hook decisions. Wanting a Repo
      here is the signal that something belongs on the server instead.
    * **No PubSub.** Nothing subscribes to anything. The processes that need to
      talk are in the same project subtree and find each other through the
      registry, by name. A PubSub with no subscribers is scaffolding.
    * **No Presence, no MCP server, no LiveView.** The tools moved to the
      server; the endpoint below serves hook routes and nothing else.
    * **No embedding serving.** Inference is phase 6. The seam is the channel —
      vectors will ride it in batches, content-addressed by fingerprint. It is
      not stubbed here, because a stub is indistinguishable from the real thing
      having silently stopped working.

  A child spec rather than an `Application` callback so the tree has two
  callers: `cms harness`, where it is the whole process, and the test suite,
  where it hangs off whichever application `mix test` booted. Tests here drive
  real processes rather than constructing them, so they need the real tree —
  and a second `Application` in one OTP app was never an option.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Web,
      CodeMySpec.BootVersion
    ]

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # A served copy's channel chain, named here at the top so the copy
    # supervisor below does not depend on the layer it starts.
    :ok = CmsHarness.Copy.Supervisor.serve_with(CmsHarness.Project.Supervisor)

    # Where this harness's code came from, recorded before anything runs. A
    # harness runs what it booted with, and when its checkout moves underneath
    # it the two can disagree about the channel contract — which surfaces as an
    # error naming neither the merge nor the harness (7e8fd1c6). Read only on a
    # failure path; see `CodeMySpec.BootVersion`.
    CodeMySpec.BootVersion.capture()

    children = [
      # A hook arrives as an HTTP request carrying a working directory, and
      # something has to turn that into that project's channel client. Without
      # a registry the endpoint cannot reach into the subtree at all. Keyed by
      # `{kind, root}` so one registry serves every process in a project,
      # and a dead process deregisters itself.
      {Registry, keys: :unique, name: CmsHarness.Registry},

      # How many analyzer runs this machine will execute at once, across every
      # working copy. `Project.AnalysisServer` serializes within a copy and
      # nothing serialized across them, so six agents wanting to promote ran six
      # full suites against one box — and under that load the analyzer invents
      # failures rather than merely being slow (`3e9b7568`).
      #
      # Above the project supervisor, because it is the one thing here that is
      # about the machine rather than about a project.
      CmsHarness.AnalysisSlots,

      # Watches every agent the engine starts, so a death is reported the
      # moment it happens (`CmsHarness.Agents.Liveness`). Before the copies,
      # so it is up to watch the first agent.
      CmsHarness.Agents.Liveness,

      # One supervisor per working copy (`CmsHarness.Copy.Supervisor`), holding
      # everything this harness runs for it: its channel chain once served, its
      # agents, its app. Copies arrive at runtime — from the environment on a
      # sprite, from a hook's working directory on a laptop — so the tree cannot
      # be static, and a subtree each means a wedged copy restarts alone: the
      # server's watcher was once a singleton managing every project at once,
      # and one project's crash stopped watching for all of them.
      #
      # Agents and the app are siblings of the channel chain under the copy, not
      # inside it: a reconnect restarts the chain, and an agent or an app must
      # not notice (story 1108). Offboarding a copy stops all of it at once.
      {DynamicSupervisor, name: CmsHarness.CopiesSupervisor, strategy: :one_for_one},

      # A copy's tunnel connector, for whichever copy holds one (see
      # `CmsHarness.AppInstance`'s own comment — a copy with no DB-backed
      # tunnel starts nothing here). Its own supervisor, not a child
      # `AppInstance` starts and merely holds a reference to: `restart:
      # :permanent`, keyed by `{:tunnel, tunnel_id}` in the same registry
      # every `:via` name here uses, means a connector that dies on its own
      # — cloudflared crashing, not `AppInstance` ever asking it to stop —
      # comes back on its own before the next `ensure_app_running`/
      # `restart_app` push would otherwise have noticed.
      {DynamicSupervisor, name: CmsHarness.TunnelSupervisor, strategy: :one_for_one},

      # Holds the short-lived token the deploy key buys, and serialises buying
      # it: several hooks and an MCP call arrive at once on a cold start, and N
      # simultaneous exchanges for one key is N-1 tokens nobody uses.
      CmsHarness.Token,

      # The dev-only age key(s) a project's channel join hands over (story
      # 1132), held only in this process's memory — never a file. Above the
      # socket that serves it, which reads it on every request.
      CmsHarness.SopsKeyring,

      # Hands the key above to `cms sops-key` (run by `sops` itself via
      # `SOPS_AGE_KEY_CMD`) over a Unix domain socket only this box's own
      # user can reach — never HTTP, never a file. `:temporary`-restarted
      # children above it mean a project disconnecting never takes this
      # down; this is the one machine-wide thing in this tree below
      # `AnalysisSlots`.
      CmsHarness.SopsKeySocket,

      # Device approval and token renewal run independently of project hooks.
      {CmsHarness.Authorization,
       Application.get_env(:code_my_spec, CmsHarness.Authorization, [])},

      # Claude Code POSTs its hooks to a fixed URL. This is that URL.
      CmsHarness.Web.Endpoint,

      # Its bound port, for the channel to report (`Config.local_port/0`) without
      # the channel depending on the web layer.
      {Task, fn -> CmsHarness.Config.record_local_port(CmsHarness.Web.bound_port()) end},

      # Keeps saying which of this machine's checkouts are still on disk. A
      # worktree is removed by a command that tells us nothing, and the copy it
      # held stops being scanned at that exact moment, so the only way to learn
      # about it is to keep looking. Here rather than in the local web app
      # because a light harness never starts that, and a light harness is the
      # sprite — the machine whose checkouts actually get thrown away.
      {CmsHarness.WorkingCopyReporter,
       Application.get_env(:code_my_spec, :working_copy_reporter, [])},

      # Keeps every app instance's log bounded, on its own clock.
      {CmsHarness.AppInstance.LogTrimmer,
       Application.get_env(:code_my_spec, :app_log_trimmer, [])}

      # Last, because it needs both the registry and the dynamic supervisor.
      # `:temporary`, which is what `{Task, fun}` means, so a failure here does
      # not take the harness down: a hook can still name its own working
      # directory, and a harness that is up and serving nothing is far easier to
      # diagnose than one that would not boot.
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

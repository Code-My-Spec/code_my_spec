defmodule CodeMySpecWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpec.Agents.GraphWake
  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Embeddings.HetznerFlameBackend
  alias CodeMySpec.Provisioning.BurstBox
  alias CodeMySpec.Users.Scope

  @impl true
  def start(_type, args) do
    env = Application.get_env(:code_my_spec, :env, :prod)
    maybe_install_file_logger()

    # Which commit is answering. A dev server runs the checkout it was started
    # from, so a fix committed, pushed and green can still be absent from every
    # response an agent sees — and because the responses in question are messages
    # about correctness, a stale one reads as the fix not working rather than as
    # the build being old. Three of those cost a diversion in one session
    # (5e59a29d). Logged once at boot and reported by `register_session`.
    CodeMySpec.BootVersion.capture()
    log_boot_version()

    children =
      [
        CodeMySpecWeb.Telemetry,
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        CodeMySpec.Environments.registry_child_spec(),
        {DNSCluster, query: Application.get_env(:code_my_spec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        {Task.Supervisor, name: CodeMySpec.TaskSupervisor},
        # Embeddings rework step 2 (577de9bb): the server does its own
        # inference now instead of trusting a harness to have embedded
        # content before it arrived. Gated on the backend actually being
        # configured (unset in :test, which stays on the ETS-backed
        # TestBackend) rather than on env name, so this follows whatever
        # `embeddings_backend` says rather than drifting from it.
        #
        # One OrtexServing, not one per priority: John's call, reviewing
        # step 2 — a plain mailbox would starve search behind a queued
        # bulk batch, so the server itself prioritises search internally
        # (see OrtexServing's own moduledoc) rather than needing two
        # instances to fake it.
        embeddings_configured?() && CodeMySpec.Embeddings.OrtexServing,
        # `min: 0` — no runner sits idle between hex-doc reconciles
        # (step 3). `max: 4` is a starting guess for round 1's
        # FLAME.LocalBackend, where a "runner" is just a local spawned
        # process rather than real infrastructure being provisioned, so
        # being wrong here costs nothing to revisit.
        #
        # Step 7 (577de9bb): prod runs real bursts on `FLAME.FlyBackend`,
        # since this app is already a Fly machine — `FLY_APP_NAME` and
        # `FLY_IMAGE_REF` are Fly's own runtime env, so the only new
        # requirement is the `FLY_API_TOKEN` secret (not auto-injected by
        # Fly for security reasons). A Hetzner backend was the original
        # plan, but the app isn't Hetzner-deployed at all — nothing
        # portable exists there yet for a runner to boot from, while Fly
        # already has exactly that. dev/test keep `LocalBackend`, where a
        # "runner" costs nothing to get wrong.
        embeddings_configured?() &&
          {FLAME.Pool, name: CodeMySpec.EmbedPool, min: 0, max: 4, backend: embed_pool_backend(env)},
        # Backstop for the live mix.lock trigger in `Files.FileSync` (step 3)
        # — not gated on `embeddings_configured?()` like the two above,
        # because `project_dependencies` is dependency bookkeeping on its
        # own, independent of whether anything embeds hex docs from it here.
        CodeMySpec.Files.LockfileSweep,
        # The hex-doc reconciler's own driver (step 3) — gated like
        # `OrtexServing`/`EmbedPool` above, since embedding is exactly what
        # it does and it has nothing to drive without them.
        embeddings_configured?() && CodeMySpec.Embeddings.HexDocSweep,
        # Framework knowledge (step 4): one reconcile per boot, no watcher. A
        # `:temporary`, non-raising Task, so it never blocks or fails boot.
        embeddings_configured?() && CodeMySpec.Embeddings.FrameworkKnowledgeReconciler,
        # How many `FLAME.call`s are in flight on `CodeMySpec.EmbedPool` right
        # now, per pool — the fact `BurstBox.busy?/3`'s embedding half needs
        # (story 877, item 1 correction) with no FLAME-internals
        # introspection. Same shape as `Faults`/`DrainCost` below: a process
        # that owns one ETS table, unconditional for the same reason they
        # are — it costs nothing idle, and gating it on
        # `embeddings_configured?()` would just be one more thing a test
        # starting its own pool has to remember to start first.
        CodeMySpec.Embeddings.InFlightCalls,
        # Per-caller failure injection, so QA can break one project's digest or
        # one visitor's intake without breaking the shared box. Owns an ETS
        # table and nothing else; only `/dev/faults` ever writes to it, and that
        # route is compile-time absent from the release.
        CodeMySpec.Faults,
        # Holds what the last graph drain cost, per project, so a reader can ask
        # rather than grep a log. Same shape as `Faults` above: a process that
        # owns one ETS table. The numbers are already emitted as telemetry; this
        # is only the most recent one, kept where the graph endpoint can reach
        # it.
        CodeMySpec.Requirements.DrainCost,
        # Guided intake conversations, one process per plan. The conversation
        # owns the flow so a LiveView can come and go without taking it — every
        # bug in that feature has been a variation on the socket holding state
        # it could not keep.
        {Registry, keys: :unique, name: CodeMySpec.Intake.ConversationRegistry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: CodeMySpec.Intake.ConversationSupervisor},
        # One watcher per project with something happening in it, turning writes
        # to the graph's inputs into a recomputed graph and a woken agent.
        # Before it, the only thing that ever recomputed was somebody reading —
        # so an idle agent never learned that work had appeared, measured at
        # ninety minutes of a product agent waiting on four untriaged issues.
        #
        # Started on demand by `GraphWatcher.ensure_watching/1` rather than one
        # per project at boot: a project nobody is working on needs no watcher.
        {Registry, keys: :unique, name: CodeMySpec.Requirements.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: CodeMySpec.Requirements.WatcherSupervisor},
        # And re-establish them for whatever was already being worked. Watchers
        # are in memory, so a restart takes them all, and a deploy is exactly
        # when agents are mid-run — an agent that goes idle after one would have
        # nothing watching for the work that wakes it.
        #
        # `:temporary` because failing to seed is not a reason to refuse to
        # boot. This used to add "the next stop decision on a project starts its
        # watcher anyway", which is not true — the only callers of
        # `ensure_watching/1` are this task and the two continuous toggles in
        # `agents.ex`, and no stop path is among them (07f42ebf, where the same
        # false self-healing claim in `DevState`'s diagnostic cost a QA cycle).
        #
        # So the consequence of a failed seed is worse than that sentence
        # implied: nothing watches until somebody toggles a loop or the server
        # restarts again. Still not a reason to refuse to boot — a server that
        # will not start helps nobody — but it is a reason to read a failure
        # here as something to act on rather than as self-correcting.
        Supervisor.child_spec(
          {Task, &GraphWake.watch_active_projects/0},
          id: :watch_active_projects,
          restart: :temporary
        ),
        # One cadence per project with agents running in it, waking the main
        # agent on an interval with the digest in hand.
        #
        # Same shape as the watcher above, and missing entirely until QA went
        # looking: `MainAgent.Cadence` was written, supervised by nobody, and
        # called `start_link/1` from nowhere, so no check-in ever fired — the
        # story's whole promise, that a problem surfaces even when the agent in
        # trouble cannot report it, silently did not happen.
        #
        # Nothing said so. `running?/1` reads the stood-down set, so it answered
        # true for every project that had never stood down, including every one
        # with no timer at all; and the spex start the process themselves, so
        # they proved the loop and not the wiring.
        {Registry, keys: :unique, name: CodeMySpec.MainAgent.CadenceRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: CodeMySpec.MainAgent.CadenceSupervisor},
        # And re-establish them after a restart, for the reason the watcher's
        # seeding gives: timers are in memory and a deploy lands mid-run.
        # `:temporary` on the same grounds — failing to seed is not a reason to
        # refuse to boot.
        Supervisor.child_spec(
          {Task, &CodeMySpec.MainAgent.wake_active_projects/0},
          id: :wake_active_projects,
          restart: :temporary
        ),
        # Which projects a light harness is holding, and therefore where their
        # analyzers run. Here rather than in `Analysis.Supervisor` because that
        # subtree only starts where analyzers run locally, and this table is
        # about the projects where they do not.
        CodeMySpec.Analysis.HarnessRegistry,
        # Which working copies are mid-reconcile. Same reasoning as the table
        # above — it is about state the server holds on behalf of harnesses that
        # run elsewhere, so it belongs to the web app rather than to the
        # analysis subtree.
        CodeMySpec.Files.ReconcileRegistry,
        # Which projects have a setup run in flight. Provisioning talks to real
        # providers from here, not from the local harness, so the lock that
        # keeps two runs from racing the same project belongs here too.
        CodeMySpec.Provisioning.RunLock,
        # Timers for agents the provider refused until a named time: the held
        # turn end runs then. Re-armed on a harness reconnect.
        CodeMySpec.Agents.RefusalWake,
        # Which projects have a promotion in flight. A promotion merges and
        # restarts the one running checkout a project has, and two of them at
        # once decide the surviving build by timing (db97272b) — the lock
        # that closes that belongs here for the same reason RunLock does.
        CodeMySpec.Promotion.Lock,
        # Which tunnel has an ingress read-modify-write in flight. A shared
        # tunnel's ingress list (criterion 1586) is written by more than one
        # working copy independently, and the GET-modify-PUT round trip is
        # not atomic on its own — same reasoning as the lock above, scoped to
        # a different resource.
        CodeMySpec.Workspaces.TunnelIngressLock,
        # What agents are writing before it becomes a message. Before the
        # endpoint, which is where the drafts arrive from.
        CodeMySpec.Conversations.Drafts,
        CodeMySpecWeb.Presence,
        # The harness tools. Same server module the local process runs — the
        # only difference is where scope comes from, and the tools never had to
        # know. `session_idle_timeout` matches the local mount for the same
        # reason it was raised there: an agent's workflow has long gaps between
        # MCP calls while it writes code and runs tests, and the 30-minute
        # default dropped sessions mid-run.
        {CodeMySpec.McpServers.LocalServer,
         transport: :streamable_http, session_idle_timeout: to_timeout(hour: 4)},
        {CodeMySpec.McpServers.ComponentsServer, transport: :streamable_http},
        {CodeMySpec.McpServers.IssuesServer, transport: :streamable_http},
        {CodeMySpec.McpServers.GscServer, transport: :streamable_http},
        {CodeMySpec.McpServers.Ga4Server, transport: :streamable_http},
        {CodeMySpec.McpServers.GoogleAdsServer, transport: :streamable_http},
        CodeMySpecWeb.Endpoint
      ]
      |> Enum.filter(& &1)
      |> children(env)
      # CodeMySpecDesktop.Application adds its own children here.
      |> then(Keyword.get(args, :children, & &1))

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        GoogleAnalytics.attach()
        AnalysisReport.attach()
        GraphWake.attach()
        ok

      other ->
        other
    end
  end

  # Alongside stdout, never instead of it: in prod that stream is what `fly logs`
  # reads, and in dev it is the terminal the developer is watching.
  #
  # Without this the dev server's only log was that terminal's scrollback, which
  # nobody but its owner can reach — so questions about :4000 got answered from
  # server.log, a different process on a different port, and answered wrongly.
  defp log_boot_version do
    Logger.info("[Boot] serving #{CodeMySpec.BootVersion.describe()}")
  end

  defp embeddings_configured? do
    Application.get_env(:code_my_spec, :embeddings_backend) ==
      CodeMySpec.Embeddings.PgVectorBackend
  end

  # Hetzner is the capability (story 877) — never activated by this alone.
  # `hetzner_burst_box_configured?/0` is the gate: present and valid, same as
  # `FLY_API_TOKEN` was meant to be for `FlyBackend` above, this wins; absent,
  # :prod falls back to `FlyBackend` exactly as before this existed. Dev and
  # test are untouched either way — `embed_pool_backend/1` is never called
  # for them at all (see `embeddings_configured?/0` above).
  defp embed_pool_backend(:prod) do
    if hetzner_burst_box_configured?() do
      configure_hetzner_flame_backend!()
      HetznerFlameBackend
    else
      FLAME.FlyBackend
    end
  end

  defp embed_pool_backend(_env), do: FLAME.LocalBackend

  defp hetzner_burst_box_configured? do
    case System.get_env("HETZNER_API_TOKEN") do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  # The three closures `HetznerFlameBackend`'s own moduledoc already
  # sketches, built here rather than inside either boundary: `Embeddings` and
  # `Provisioning` are both `top_level?: true` with no dependency between
  # them (see that module's own moduledoc for the forbidden-reference this
  # avoids), so the wiring can only happen where both are already in scope —
  # this module already depends on `CodeMySpec.Provisioning` (`RunLock`
  # above) and on `CodeMySpec.Embeddings` (`OrtexServing`, `HexDocSweep`
  # above).
  #
  # `%Scope{}` — no account, no project — is the platform acting for itself,
  # the same reading `BurstBox.ensure_box/3`'s own `platform_scope?/1` and
  # `Hetzner.token/1`'s application-config fallback both already give that
  # shape of scope.
  defp configure_hetzner_flame_backend! do
    platform_scope = %Scope{}

    Application.put_env(:flame, HetznerFlameBackend,
      box_name: BurstBox.box_name(),
      ensure_box: fn name -> BurstBox.ensure_box(platform_scope, name) end,
      start_runner: fn server, runner_name, env ->
        BurstBox.start_runner(platform_scope, server, runner_name, env)
      end,
      stop_runner: fn server, runner_name ->
        BurstBox.stop_runner(platform_scope, server, runner_name)
      end
    )
  end

  defp maybe_install_file_logger do
    if Application.get_env(:code_my_spec, :install_file_logger, false) do
      CodeMySpec.Logging.install_file_handler!(
        source: "web",
        instance: System.pid(),
        handler_id: :cms_web_file,
        replace_default: false
      )
    end
  end

  def children(children, :dev) do
    tunnel_config = Application.get_env(:code_my_spec, :cloudflare_tunnel, [])

    tunnel_opts =
      Keyword.merge(tunnel_config,
        endpoint: CodeMySpecWeb.Endpoint,
        otp_app: :code_my_spec,
        origin_url:
          tunnel_config[:origin_url] || "http://127.0.0.1:#{System.get_env("PORT") || "4000"}",
        enabled: main_copy?() and not tunnel_held_by_harness?()
      )

    children ++ [{ClientUtils.CloudflareTunnel, tunnel_opts}]
  end

  def children(children, :test) do
    # Local web endpoint is needed for spex tests that drive the local UI;
    # the Analysis run service backs the stop-hook paths those tests hit. The
    # harness data-plane (Presence + WorkSource) rides with the local endpoint
    # so harness channel tests have them available.
    children ++
      [
        CodeMySpec.Analysis.Supervisor,
        CodeMySpecLocalWeb.Presence,
        CodeMySpec.AgentHarness.WorkSource,
        CodeMySpecLocalWeb.Endpoint
      ]
  end

  def children(children, _), do: children

  # `tunnel_config` is main's own tunnel — a hardcoded hostname, tunnel id and
  # account tag in this file, read unconditionally by every :dev boot. A
  # non-main working copy booting the same way (`CmsHarness.AppInstance`,
  # story 1108) started this GenServer too, which ran a second `cloudflared`
  # answering for main's tunnel from a different port — harmless only because
  # every copy's config named the same origin main's did, and a live risk the
  # moment one didn't (Cloudflare splitting main's public traffic between the
  # two apps). `CMS_MAIN_COPY` is set by `AppInstance.Runner.Local.launch/7`
  # for exactly this reason; unset (a developer's own `mix phx.server`, not
  # going through the harness at all) reads as main, matching every boot
  # before this existed.
  defp main_copy?, do: System.get_env("CMS_MAIN_COPY") != "false"

  # The other half of the same fact `CmsHarness.AppInstance.ensure_tunnel/3`
  # acts on: `true` exactly when this copy's tunnel is DB-backed
  # (`PreviewTunnel.stored_credentials/1` found one) and the harness is
  # therefore already running — or about to run — the connector for it
  # itself. This dev tunnel's own `tunnel_config` above is a config-only
  # bootstrap with no DB row, so `stored_credentials/1` finds nothing for it
  # and this reads `false` — the app keeps running its own, exactly as
  # before this existed. Set by `AppInstance.Runner.Local.launch/7`; unset
  # (a developer's own `mix phx.server`) reads as `false`, the same
  # not-going-through-the-harness default `main_copy?/0` uses.
  defp tunnel_held_by_harness?, do: System.get_env("CMS_TUNNEL_HELD_BY_HARNESS") == "true"

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CodeMySpecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

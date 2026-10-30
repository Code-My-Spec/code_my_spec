defmodule CodeMySpecWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpec.Agents.Events
  alias CodeMySpec.Agents.GraphWake
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Embeddings.HetznerFlameBackend
  alias CodeMySpec.Notifications.AnalysisPush
  alias CodeMySpec.Provisioning.BurstBox
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.AgentTasks.RunReconciled
  alias CodeMySpec.Agents.ValidationHoldReport
  alias CodeMySpec.Staffing

  @impl true
  def start(_type, args) do
    env = Application.get_env(:code_my_spec, :env, :prod)
    maybe_install_file_logger()

    # Which commit is answering; logged at boot and reported by `register_session`.
    # See knowledge/web, "Boot".
    CodeMySpec.BootVersion.capture()
    log_boot_version()

    setup_opentelemetry(env)

    # Children that act outside this process start only when this boot serves
    # (`when_serving/2`).
    # See knowledge/web, "Boot".
    serving? = Phoenix.Endpoint.server?(:code_my_spec, CodeMySpecWeb.Endpoint)

    children =
      [
        CodeMySpecWeb.Telemetry,
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        CodeMySpec.ExecutionContexts.registry_child_spec(),
        {DNSCluster, query: Application.get_env(:code_my_spec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        {Task.Supervisor, name: CodeMySpec.TaskSupervisor},
        # Flows parked under their OAuth `state`: the desktop window's, and an
        # agent's `connect_provider`, finished in whatever browser the person has.
        CodeMySpec.Integrations.OAuthHandoff,
        # Gated on the configured backend, not the env name (`:test` stays on
        # the ETS TestBackend). One serving: it prioritises search internally.
        embeddings_configured?() && CodeMySpec.Embeddings.OrtexServing,
        # `min: 0`: no idle runner between reconciles. Backend per env in
        # `embed_pool_backend/1`.
        embeddings_configured?() &&
          {FLAME.Pool,
           name: CodeMySpec.EmbedPool, min: 0, max: 4, backend: embed_pool_backend(env)},
        # Backstop for the live mix.lock trigger in `Files.FileSync`. Not gated on
        # embeddings: `project_dependencies` is bookkeeping on its own.
        # Test and spex runs launched here never outlive what started them.
        when_serving(serving?, CodeMySpec.RunGuard),
        when_serving(serving?, CodeMySpec.Files.LockfileSweep),
        when_serving(serving?, embeddings_configured?() && CodeMySpec.Embeddings.HexDocSweep),
        # Deletes idle deploy burst boxes and leftover builders in prod when
        # the Hetzner API is configured.
        when_serving(serving?, burst_sweep_child(env)),
        # One reconcile per boot; a `:temporary`, non-raising Task, so it never
        # blocks or fails boot.
        when_serving(
          serving?,
          embeddings_configured?() && CodeMySpec.Embeddings.FrameworkKnowledgeReconciler
        ),
        # In-flight `FLAME.call`s per pool, for `BurstBox.busy?/3`. One ETS
        # table, unconditional: costs nothing idle.
        CodeMySpec.Embeddings.InFlightCalls,
        # Per-caller failure injection for QA. Only `/dev/faults` writes it, and
        # that route is compile-time absent from the release.
        CodeMySpec.Faults,
        # The last graph drain's cost per project, for the graph endpoint.
        CodeMySpec.Requirements.DrainCost,
        # File verdicts computed for copies whose harness has no current report.
        CodeMySpec.Requirements.CopyOverlay.Cache,
        # Intake conversations, one process per plan, so the flow outlives any
        # LiveView.
        # See knowledge/web, "Intake workspace".
        {Registry, keys: :unique, name: CodeMySpec.Intake.ConversationRegistry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: CodeMySpec.Intake.ConversationSupervisor},
        # One worker per project with a promotion queue (`PromotionQueue`).
        {Registry, keys: :unique, name: CodeMySpec.PromotionQueue.Registry},
        {DynamicSupervisor, name: CodeMySpec.PromotionQueue.Supervisor, strategy: :one_for_one},
        # Graph watchers, one per active project, started on demand by
        # `GraphWatcher.ensure_watching/1`.
        {Registry, keys: :unique, name: CodeMySpec.Requirements.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: CodeMySpec.Requirements.WatcherSupervisor},
        # Re-seeds watchers after a restart. `:temporary`: a failed seed must
        # not stop boot, but it is not self-correcting.
        # See knowledge/web, "Boot".
        when_serving(
          serving?,
          Supervisor.child_spec(
            {Task, &GraphWake.watch_active_projects/0},
            id: :watch_active_projects,
            restart: :temporary
          )
        ),
        # One cadence per project with agents running, waking the main agent on
        # an interval with the digest.
        # See knowledge/web, "Boot".
        {Registry, keys: :unique, name: CodeMySpec.Agents.Main.CadenceRegistry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: CodeMySpec.Agents.Main.CadenceSupervisor},
        # Re-seeds cadences after a restart; `:temporary` like the watcher seed.
        when_serving(
          serving?,
          Supervisor.child_spec(
            {Task, &MainAgent.wake_active_projects/0},
            id: :wake_active_projects,
            restart: :temporary
          )
        ),
        # Which projects a light harness holds (so where their analyzers run).
        # Not in `Analysis.Supervisor`, which starts only where analyzers run locally.
        CodeMySpec.Analysis.HarnessRegistry,
        # What runs report as they go, for the run page (story 1141).
        CodeMySpec.Analysis.LiveRuns,
        # Working copies mid-reconcile; server-held state for remote harnesses.
        CodeMySpec.Files.ReconcileRegistry,
        # One setup run per project; provisioning calls providers from here.
        CodeMySpec.Provisioning.RunLock,
        # One app start/restart/stop run per working copy; a second would
        # overlap the first's own _build directory otherwise (issue f2977826).
        CodeMySpec.AppInstances.AppRunLock,
        # Timers for agents the provider refused until a named time: the held
        # turn end runs then. Re-armed on a harness reconnect.
        CodeMySpec.Agents.RefusalWake,
        # One promotion per project: two at once would pick the surviving build
        # by timing.
        CodeMySpec.Promotion.Lock,
        # Serialises a shared tunnel's ingress GET-modify-PUT across working copies.
        CodeMySpec.Workspaces.TunnelIngressLock,
        # Agents' in-progress drafts. Before the endpoint, which delivers them.
        CodeMySpec.Conversations.Drafts,
        CodeMySpecWeb.Presence,
        # Which agents' processes are alive, tracked by their copies' channels.
        CodeMySpec.Agents.Presence,
        # The harness tools, same module as the local mount. A 4h idle timeout:
        # agents go long between MCP calls, and the 30-minute default dropped
        # sessions mid-run.
        {CodeMySpec.McpServers.LocalServer,
         transport: :streamable_http, session_idle_timeout: to_timeout(hour: 4)},
        {CodeMySpec.McpServers.ComponentsServer, transport: :streamable_http},
        {CodeMySpec.McpServers.GscServer, transport: :streamable_http},
        {CodeMySpec.McpServers.Ga4Server, transport: :streamable_http},
        {CodeMySpec.McpServers.GoogleAdsServer, transport: :streamable_http},
        # Settle the previous server's run ledger before a harness can join.
        # Main serves remote harnesses even though it has no local analyzer supervisor.
        when_serving(serving? and env != :test, CodeMySpec.Analysis.BootRecovery),
        CodeMySpecWeb.Endpoint,
        when_serving(serving?, CodeMySpec.Agents.Mailbox.Reconciler),
        {CodeMySpecWeb.TelemetryHandlers, telemetry_handlers()}
      ]
      |> Enum.filter(& &1)
      |> children(env, serving?)
      # CodeMySpecDesktop.Application adds its own children here.
      |> then(Keyword.get(args, :children, & &1))

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        GoogleAnalytics.attach()
        AnalysisReport.attach()
        ValidationHoldReport.attach()
        Events.attach()
        RunReconciled.attach()
        AnalysisPush.attach()
        Staffing.attach()
        # A copy's app holds main's open candidates in its cloned database;
        # resuming them there would gate and publish beside main.
        when_serving(serving? and main_copy?(), &CodeMySpec.PromotionQueue.resume_all/0)
        GraphWake.attach()
        ok

      other ->
        other
    end
  end

  # Attached at boot below; `TelemetryHandlers` puts back any that come off.
  defp telemetry_handlers do
    [
      {"GoogleAnalytics", &GoogleAnalytics.attach/0},
      {"AnalysisReport", &AnalysisReport.attach/0},
      {"ValidationHoldReport", &ValidationHoldReport.attach/0},
      {"Events", &Events.attach/0},
      {"RunReconciled", &RunReconciled.attach/0},
      {"AnalysisPush", &AnalysisPush.attach/0},
      {"Staffing", &Staffing.attach/0},
      {"GraphWake", &GraphWake.attach/0}
    ]
  end

  defp log_boot_version do
    Logger.info("[Boot] serving #{CodeMySpec.BootVersion.describe()}")
  end

  defp embeddings_configured? do
    Application.get_env(:code_my_spec, :embeddings_backend) ==
      CodeMySpec.Embeddings.PgVectorBackend
  end

  # Prod: Hetzner when `HETZNER_API_TOKEN` is set, else Fly when `FLY_API_TOKEN`
  # is, else local. Checked here because a backend's `init/1` runs lazily, so a
  # missing token would only show as every burst failing.
  defp embed_pool_backend(:prod) do
    cond do
      hetzner_burst_box_configured?() ->
        configure_hetzner_flame_backend!()
        HetznerFlameBackend

      fly_api_token_configured?() ->
        FLAME.FlyBackend

      true ->
        FLAME.LocalBackend
    end
  end

  defp embed_pool_backend(_env), do: FLAME.LocalBackend

  # `%Scope{}` is the platform acting for itself, as for the FLAME backend
  # below. `busy?` counts a connected embed runner as well as a running build,
  # which `BurstBox.busy?/2`'s default does not.
  defp burst_sweep_child(:prod) do
    if hetzner_burst_box_configured?() do
      {BurstBox.Sweep,
       scope: %Scope{},
       reap_legacy_builders: true,
       busy?: fn scope, server ->
         BurstBox.busy?(scope, server,
           embed_runner_busy?: fn -> CodeMySpec.embedding_runner_busy?() end
         )
       end}
    end
  end

  defp burst_sweep_child(_env), do: nil

  defp hetzner_burst_box_configured? do
    case System.get_env("HETZNER_API_TOKEN") do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  defp fly_api_token_configured? do
    case System.get_env("FLY_API_TOKEN") do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  # Wired here because `Embeddings` and `Provisioning` are separate top-level
  # boundaries that may not reference each other. `%Scope{}` (no account, no
  # project) is the platform acting for itself.
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

  # Alongside stdout, never instead of it: prod's `fly logs` and dev's terminal
  # read that stream.
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

  # A child (or, for a function, a call) only when this boot serves; `nil`
  # otherwise, which the child list filters out.
  defp when_serving(false, _thing), do: nil
  defp when_serving(true, fun) when is_function(fun, 0), do: fun.()
  defp when_serving(true, child), do: child

  def children(children, :dev, serving?) do
    tunnel_config = Application.get_env(:code_my_spec, :cloudflare_tunnel, [])

    tunnel_opts =
      Keyword.merge(tunnel_config,
        endpoint: CodeMySpecWeb.Endpoint,
        otp_app: :code_my_spec,
        origin_url:
          tunnel_config[:origin_url] || "http://127.0.0.1:#{System.get_env("PORT") || "4000"}",
        enabled: serving? and main_copy?() and not tunnel_held_by_harness?()
      )

    children ++ [{ClientUtils.CloudflareTunnel, tunnel_opts}] ++ copy_analysis(main_copy?())
  end

  def children(children, :test, _serving?) do
    # The Analysis run service backs the stop-hook paths the integration
    # suite hits.
    children ++
      [
        CodeMySpec.Analysis.Supervisor,
        CodeMySpec.AgentHarness.WorkSource
      ]
  end

  def children(children, _env, _serving?), do: children

  # Instrumentation only attaches handlers; nothing leaves the node unless
  # config/runtime.exs switched the exporter on. Not under test, where the
  # handlers would only add work to every request and query.
  defp setup_opentelemetry(:test), do: :ok

  defp setup_opentelemetry(_env) do
    OpentelemetryLoggerMetadata.setup()
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
    OpentelemetryEcto.setup([:code_my_spec, :repo])
    OpentelemetryOban.setup()
  end

  # A copy's own app has no harness, so it runs analysis itself: what QA drives
  # through `/dev/qa-agents` before a change lands. Main's sends it to its harness.
  defp copy_analysis(true), do: []

  defp copy_analysis(false) do
    # Where the runs it executes report their events as they happen (story 1141).
    # `QaEnvironments` owns, and on boot restores, what `/dev/qa-agents` registers.
    [
      CodeMySpec.Analysis.Supervisor,
      CodeMySpec.Analysis.LocalRunLink,
      CodeMySpecWeb.QaEnvironments
    ]
  end

  # `tunnel_config` is main's tunnel; only main may run its connector.
  # See knowledge/web, "Dev tunnel".
  defp main_copy?, do: CodeMySpec.AppRole.main_copy?()

  # True when the harness runs this copy's (DB-backed) tunnel connector itself.
  # Unset reads as false.
  defp tunnel_held_by_harness?, do: System.get_env("CMS_TUNNEL_HELD_BY_HARNESS") == "true"

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CodeMySpecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

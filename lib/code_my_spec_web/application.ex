defmodule CodeMySpecWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias CodeMySpec.Analytics.GoogleAnalytics

  @impl true
  def start(_type, _args) do
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
      |> children(env)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = ok ->
        GoogleAnalytics.attach()
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
          tunnel_config[:origin_url] || "http://127.0.0.1:#{System.get_env("PORT") || "4000"}"
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CodeMySpecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

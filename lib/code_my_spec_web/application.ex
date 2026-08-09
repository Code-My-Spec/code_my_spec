defmodule CodeMySpecWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias CodeMySpec.Analytics.GoogleAnalytics

  @impl true
  def start(_type, _args) do
    env = Application.get_env(:code_my_spec, :env, :prod)
    maybe_install_file_logger()

    children =
      [
        CodeMySpecWeb.Telemetry,
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        CodeMySpec.Environments.registry_child_spec(),
        {DNSCluster, query: Application.get_env(:code_my_spec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        {Task.Supervisor, name: CodeMySpec.TaskSupervisor},
        # Which projects a light harness is holding, and therefore where their
        # analyzers run. Here rather than in `Analysis.Supervisor` because that
        # subtree only starts where analyzers run locally, and this table is
        # about the projects where they do not.
        CodeMySpec.Analysis.HarnessRegistry,
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

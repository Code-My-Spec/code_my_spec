defmodule CodeMySpecWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias CodeMySpec.Analytics.GoogleAnalytics

  @impl true
  def start(_type, _args) do
    env = Application.get_env(:code_my_spec, :env, :prod)

    children =
      [
        CodeMySpecWeb.Telemetry,
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        CodeMySpec.Environments.registry_child_spec(),
        {DNSCluster, query: Application.get_env(:code_my_spec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        CodeMySpecWeb.Presence,
        {CodeMySpec.McpServers.ComponentsServer, transport: :streamable_http},
        {CodeMySpec.McpServers.IssuesServer, transport: :streamable_http},
        {CodeMySpec.McpServers.GscServer, transport: :streamable_http},
        {CodeMySpec.McpServers.Ga4Server, transport: :streamable_http},
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

  def children(children, :dev) do
    tunnel_config = Application.get_env(:code_my_spec, :cloudflare_tunnel, [])

    tunnel_opts =
      Keyword.merge(tunnel_config,
        endpoint: CodeMySpecWeb.Endpoint,
        otp_app: :code_my_spec,
        origin_url: tunnel_config[:origin_url] || "http://127.0.0.1:#{System.get_env("PORT") || "4000"}"
      )

    children ++ [{ClientUtils.CloudflareTunnel, tunnel_opts}]
  end

  def children(children, :test) do
    # Local web endpoint is needed for spex tests that drive the local UI.
    children ++ [CodeMySpecLocalWeb.Endpoint]
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

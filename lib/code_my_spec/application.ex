defmodule CodeMySpec.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    env = Application.get_env(:code_my_spec, :env, :prod)

    children =
      [
        CodeMySpecWeb.Telemetry,
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        {DNSCluster, query: Application.get_env(:code_my_spec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        CodeMySpecWeb.Presence,
        Hermes.Server.Registry,
        {CodeMySpec.McpServers.StoriesServer, transport: :streamable_http},
        {CodeMySpec.McpServers.ComponentsServer, transport: :streamable_http},
        {CodeMySpec.McpServers.AnalyticsAdminServer, transport: :streamable_http},
        CodeMySpecWeb.Endpoint
      ]
      |> children(env)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def children(children, :dev) do
    dev_children =
      if Application.get_env(:code_my_spec, :watch_content, false) do
        [CodeMySpec.ContentSync.FileWatcher]
      else
        []
      end

    children ++ dev_children
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

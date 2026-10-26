defmodule CodeMySpec.Workspaces.Runner.ClaudeCodeCloud do
  @moduledoc """
  A dev box in a Claude Code cloud environment (claude.ai/code).

  The environment runs the harness from a setup script and reaches only the hosts
  it allows. The box's token goes in as a network secret for this server's host:
  its value is the bare token, because Anthropic's proxy adds `Bearer ` itself
  (story 1131). Never an environment variable, which anyone using the
  environment can read.

  Anthropic runs the machine, so the lifecycle callbacks have nothing to start
  or stop here: whether it is up is the harness's presence (story 1138), not a
  process this server can look at.
  """
  @behaviour CodeMySpec.Workspaces.Runner

  # John's working setup (2026-10-20), less the two probe leftovers; this
  # server's own host is added.
  @hosts ~w(
    github.com
    objects.githubusercontent.com
    release-assets.githubusercontent.com
    hex.pm
    repo.hex.pm
    builds.hex.pm
    archive.ubuntu.com
    security.ubuntu.com
    apt.postgresql.org
    *.crates.io
  )

  @impl true
  def start(_container_name, _app_name, _port, _env), do: {:error, :hosted_by_provider}

  @impl true
  def url(_container_name, _port), do: ""

  @impl true
  def healthy?(_port), do: false

  @impl true
  def serving(_port), do: :down

  @impl true
  def alive?(_container_name), do: false

  @impl true
  def logs(_container_name), do: ""

  @impl true
  def stop(_container_name), do: :ok

  @impl true
  def id, do: :claude_code_cloud

  @impl true
  def label, do: "Claude Code cloud"

  @impl true
  def kind, do: :cloud

  @impl true
  def instructions(%{server_url: server_url, token: token} = context) do
    host = URI.parse(server_url).host || server_url
    port = Map.get(context, :harness_port, default_harness_port())

    [
      %{
        key: "setup-script",
        copy: "copy-setup-script",
        title: "Setup script",
        body: setup_script(server_url, host, port)
      },
      %{
        key: "setup-hosts",
        copy: "copy-setup-hosts",
        title: "Hosts to allow",
        body: Enum.join(Enum.uniq([host | hosts_for(host)]), "\n")
      },
      %{
        key: "setup-network-secret",
        copy: "copy-network-secret",
        title: "Network secret",
        body:
          "Add a network secret for #{host} whose value is exactly this token, with no " <>
            "\"Bearer \" in front (the proxy adds it):\n\n#{token}",
        # What the copy button holds: the bare token and nothing else.
        value: token
      }
    ]
  end

  defp hosts_for(host), do: [root_domain(host) | @hosts]

  defp root_domain(host) do
    host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end

  defp default_harness_port do
    if Application.get_env(:code_my_spec, :env) == :dev, do: 4004, else: 4003
  end

  defp setup_script(server_url, host, port) when is_integer(port) and port in 1..65535 do
    File.read!(script_path())
    |> String.replace("__SERVER_URL__", server_url)
    |> String.replace("__SERVER_HOST__", host)
    |> String.replace("__HARNESS_PORT__", Integer.to_string(port))
  end

  defp script_path do
    Path.join(:code.priv_dir(:code_my_spec), "dev_boxes/claude_code_cloud_setup.sh")
  end
end

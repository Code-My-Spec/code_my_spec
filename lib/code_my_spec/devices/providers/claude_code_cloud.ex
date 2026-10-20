defmodule CodeMySpec.Devices.Providers.ClaudeCodeCloud do
  @moduledoc """
  A dev box in a Claude Code cloud environment (claude.ai/code).

  The environment runs the harness from a setup script and reaches only the hosts
  it allows. The box's token goes in as a network secret for this server's host:
  its value is the bare token, because Anthropic's proxy adds `Bearer ` itself
  (story 1131). Never an environment variable, which anyone using the
  environment can read.
  """
  @behaviour CodeMySpec.Devices.Provider

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
  def id, do: :claude_code_cloud

  @impl true
  def label, do: "Claude Code cloud"

  @impl true
  def kind, do: :cloud

  @impl true
  def instructions(%{server_url: server_url, token: token}) do
    host = URI.parse(server_url).host || server_url

    [
      %{
        key: "setup-script",
        copy: "copy-setup-script",
        title: "Setup script",
        body: setup_script(server_url, host)
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
            "\"Bearer \" in front (the proxy adds it):\n\n#{token}"
      }
    ]
  end

  defp hosts_for(host), do: [root_domain(host) | @hosts]

  defp root_domain(host) do
    host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end

  defp setup_script(server_url, host) do
    File.read!(script_path())
    |> String.replace("__SERVER_URL__", server_url)
    |> String.replace("__SERVER_HOST__", host)
  end

  defp script_path do
    Path.join(:code.priv_dir(:code_my_spec), "dev_boxes/claude_code_cloud_setup.sh")
  end
end

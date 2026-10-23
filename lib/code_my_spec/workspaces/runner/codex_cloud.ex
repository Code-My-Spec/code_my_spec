defmodule CodeMySpec.Workspaces.Runner.CodexCloud do
  @moduledoc """
  A provider-hosted Codex environment for a CodeMySpec Phoenix generation target.

  Installation, process startup and conversation registration are separate:
  a cached filesystem does not retain a running database or an agent identity.
  The copyable bundle contains public configuration only. Device authorization
  happens on the machine, with credentials kept in its private state directory.
  """
  @behaviour CodeMySpec.Workspaces.Runner

  @assets ~w(codex_cloud.py codex_cloud_boot.exs)
  @hosts ~w(github.com release-assets.githubusercontent.com builds.hex.pm hex.pm repo.hex.pm
            archive.ubuntu.com security.ubuntu.com deb.debian.org apt.postgresql.org
            registry-1.docker.io auth.docker.io production.cloudflare.docker.com
            static.rust-lang.org sh.rustup.rs crates.io index.crates.io static.crates.io)

  @impl true
  def id, do: :codex_cloud
  @impl true
  def label, do: "Codex Cloud"
  @impl true
  def kind, do: :cloud
  @impl true
  def start(_name, _app, _port, _env), do: {:error, :hosted_by_provider}
  @impl true
  def url(_name, _port), do: ""
  @impl true
  def healthy?(_port), do: false
  @impl true
  def serving(_port), do: :down
  @impl true
  def alive?(_name), do: false
  @impl true
  def logs(_name), do: ""
  @impl true
  def stop(_name), do: :ok

  @impl true
  def instructions(%{server_url: server, project_id: project, device_id: device} = context) do
    config = %{
      server_url: server,
      project_id: project,
      device_id: device,
      target: Map.get(context, :target, "phoenix"),
      harness_version: Application.spec(:code_my_spec, :vsn) |> to_string()
    }

    bundle = Map.new(@assets, &{&1, read_asset(&1)}) |> Jason.encode!() |> Base.encode64()
    encoded = config |> Jason.encode!() |> Base.encode64()

    installer =
      read_asset("codex_cloud_setup.sh")
      |> String.replace("__CONTEXT__", encoded)
      |> String.replace("__RUNTIME_BUNDLE__", bundle)

    state = "${CMS_CLOUD_STATE_DIR:-$HOME/.codemyspec/codex-cloud/#{device}}"

    [
      section("setup-script", "Installation script — Phoenix (CodeMySpec)", installer),
      section("startup-script", "Startup script", """
      # Run on every fresh or resumed environment, from the generation target's repository.
      python3 "#{state}/codex_cloud.py" start --root "$PWD"
      """),
      section("setup-environment", "Environment and agent startup", """
      Generation target: Phoenix (CodeMySpec).
      Install from the target repository. Its .tool-versions and mix.lock define its toolchain and dependencies.
      Run the startup script after installation and whenever the environment resumes.
      Before running project commands in an interactive shell, load the installed toolchain:
      source "#{state}/environment.sh"
      Give each Codex conversation its own CODEX_THREAD_ID. At the start of every conversation run:
      python3 "#{state}/codex_cloud.py" session --root "$PWD"
      The helper registers the conversation and verifies start_task and evaluate_task after the complete MCP handshake.
      Keep HTTPS_PROXY and the platform's trusted CA configuration available for cloud networking.
      Configure project-specific runtime secrets in the environment's secure settings; never paste them into scripts.
      CMS_CLOUD_STATE_DIR optionally overrides the persistent private state directory.
      """),
      section(
        "setup-hosts",
        "Hosts to allow",
        Enum.join(Enum.uniq([URI.parse(server).host | @hosts]), "\n")
      ),
      section("setup-auth", "Authorize this dev box", """
      This box uses its own device identity: #{device}.
      Startup displays a device authorization URL and code when approval is required on #{server}.
      Open that URL, approve the code, then let startup finish. Credentials stay in private files on the box.
      Do not paste a deploy key or access token into these scripts. Existing desktop authentication is unchanged.
      A box is ready only when target validation passes and its harness is connected and watching the target repository.
      """)
    ]
  end

  defp section(key, title, body),
    do: %{key: key, copy: "copy-#{key}", title: title, body: body}

  defp read_asset(name),
    do: File.read!(Path.join([:code.priv_dir(:code_my_spec), "dev_boxes", name]))
end

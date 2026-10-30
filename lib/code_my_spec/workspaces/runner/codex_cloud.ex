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
      section(
        "setup-platform",
        "Required platform",
        "Codex Cloud requires x86_64 Linux. The harness artifact is cms-linux-x64.tar.gz. Choose an x86_64 Linux image before running setup."
      ),
      section(
        "setup-script",
        "Installation script — Phoenix (CodeMySpec) — x86_64 Linux",
        installer
      ),
      section("startup-script", "Startup script — reconnect an existing environment", """
      # Run on every fresh or resumed environment, from the generation target's repository.
      python3 "#{state}/codex_cloud.py" start --root "$PWD"
      """),
      section("setup-environment", "Cloud environment settings", """
      Use this project's Phoenix repository, with committed mix.exs, mix.lock and .tool-versions.
      Add the allowed hosts below and keep network access available during agent turns as well as setup.
      Keep HTTPS_PROXY and the platform's trusted CA configuration available.
      Configure project-specific runtime secrets in the environment's secure settings.
      CMS_CLOUD_STATE_DIR optionally overrides the persistent private state directory.
      Run the installation script in the repository root. Installation prepares the environment;
      the start-or-resume prompt below connects the agent and handles device authorization.
      """),
      section("setup-conversation", "Start or resume — paste into your cloud chat", """
      Connect this Codex conversation to CodeMySpec at #{server} for project #{project}.
      Use the existing setup for device #{device}; run from this project's Phoenix repository root.

      1. Verify CODEX_THREAD_ID identifies this actual conversation. If it is missing, use the
         current conversation ID supplied by the platform and export CODEX_THREAD_ID, or ask me for it. Never invent an ID
         or reuse another conversation's ID. Keep the same ID when resuming this conversation.
      2. Run:
         python3 "#{state}/codex_cloud.py" resume --root "$PWD"
         If the helper is missing, ask me to run this device's installation script first.
         If authorization is required, show me the verification URL and user code promptly
         and let startup continue while I approve it. Never show access or refresh tokens.
         If a command fails, report its error and the next corrective step before continuing.
      3. Continue only when startup returns ready=true, agent_id and task_tools_available=true.
         The helper registers this conversation through the existing SessionStart flow.
         Load the toolchain before project commands:
         source "#{state}/environment.sh"
      4. Discover the CMS tools through the initialized session:
         printf '%s' '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}' | python3 "#{state}/codex_cloud.py" mcp --root "$PWD"
         Use the returned tool schemas. Send tools/call JSON through the same mcp command;
         this reuses the registered agent and MCP session. Follow the CMS onboarding guidance
         and confirm this conversation's role before taking work as Main. Check existing
         tasks and messages before starting new work so resumption does not duplicate it.
      5. Report the connection result and the next pending action. Before ending a work turn,
         explicitly evaluate any task you changed with evaluate_task and save progress through
         the available CMS tools. Do not depend on desktop lifecycle hooks in this environment.

      I will resume this chat manually. Do not configure automatic wake-up or another agent runtime.
      """),
      section(
        "setup-hosts",
        "Hosts to allow",
        Enum.join(Enum.uniq([URI.parse(server).host | @hosts]), "\n")
      ),
      section("setup-auth", "Authorize this dev box", """
      This box uses its own device identity: #{device}.
      Startup displays a device authorization URL and code when approval is required on #{server}.
      Open that URL in your browser, approve the code, then let startup finish.
      Approval is needed again only when saved authorization can no longer be used or refreshed.
      Credentials stay in private files on the box.
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

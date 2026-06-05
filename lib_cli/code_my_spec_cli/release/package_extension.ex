defmodule CodeMySpecCli.Release.PackageExtension do
  @moduledoc """
  Burrito post-build step that packages the CodeMySpec Claude Code extension.

  This step:
  1. Creates a release directory with extension files
  2. Copies the binary for GitHub Release upload
  3. Creates an install script that downloads the binary

  All file paths are derived from the Burrito build context and module
  constants — no user input reaches file operations.
  """

  @behaviour Burrito.Builder.Step

  @binary_name "cms"
  @release_dir "codemyspec-extension"
  @github_repo "Code-My-Spec/plugins"
  @plugin_slug "codemyspec"

  # sobelow_skip ["Traversal"]
  @impl true
  def execute(%Burrito.Builder.Context{} = context) do
    log("Packaging CodeMySpec extension...")

    app_path = File.cwd!()
    release_name = Atom.to_string(context.mix_release.name)
    target_name = Atom.to_string(context.target.alias)

    # Source paths. Burrito appends `.exe` to Windows binaries; mirror that
    # here so the copy step finds the file regardless of target OS.
    source_basename = "#{release_name}_#{target_name}" <> source_ext(context.target)
    source_binary = Path.join([app_path, "burrito_out", source_basename])
    source_extension = Path.join(app_path, "CodeMySpec")

    # Output paths
    release_base = Path.join(app_path, "release")
    extension_dir = Path.join(release_base, @release_dir)
    binaries_dir = Path.join(release_base, "binaries")

    File.rm_rf!(binaries_dir)
    File.mkdir_p!(binaries_dir)

    # Plugin file shuffle — copy, port rewrite, marketplace.json, README,
    # install.sh, .gitignore. Lives in its own function so `mix cms.package_plugin`
    # can run the same dance without a burrito context.
    package_plugin_files(source_extension, extension_dir)

    # Copy binary for GitHub Release
    binary_name = binary_name_for_target(context.target)
    target_binary = Path.join(binaries_dir, binary_name)
    File.copy!(source_binary, target_binary)
    File.chmod!(target_binary, 0o755)
    log("Copied binary to #{target_binary}")

    log("Extension packaged to: #{extension_dir}")
    log("Binary ready for upload: #{target_binary}")

    # Get version from plugin.json
    version = get_plugin_version(extension_dir)

    # Push to GitHub and create release (if PUBLISH_RELEASE env var is set)
    if System.get_env("PUBLISH_RELEASE") == "true" do
      log("Publishing release v#{version}...")
      push_to_github(extension_dir, version)
      create_github_release(target_binary, binary_name, version)
      log("Release v#{version} published!")
    else
      log("Skipping publish (set PUBLISH_RELEASE=true to publish)")
    end

    context
  end

  @doc """
  Runs the plugin file-shuffling steps (copy, port rewrite, marketplace.json,
  install.sh, README, .gitignore) into `extension_dir`.

  Pure file I/O — no burrito, no binary, no GitHub. `mix cms.package_plugin`
  uses this to lay out the release locally for inspection.

  Returns `%{extension_dir: ..., plugin_dest: ...}`.
  """
  # sobelow_skip ["Traversal"]
  def package_plugin_files(source_extension, extension_dir) do
    plugin_dest = Path.join([extension_dir, "plugins", @plugin_slug])

    File.rm_rf!(extension_dir)
    File.mkdir_p!(plugin_dest)

    copy_extension_files(source_extension, plugin_dest)
    log("Copied plugin files into plugins/#{@plugin_slug}/")

    rewrite_dev_port(plugin_dest)
    log("Rewrote dev port 4004 -> prod port 4003")

    create_marketplace_json(extension_dir, plugin_dest)
    log("Created marketplace.json")

    create_install_script(extension_dir)
    log("Created install script")

    create_install_ps1(extension_dir)
    log("Created Windows install.ps1")

    create_readme(extension_dir)
    log("Created README")

    create_gitignore(extension_dir)

    %{extension_dir: extension_dir, plugin_dest: plugin_dest}
  end

  # sobelow_skip ["Traversal"]
  defp get_plugin_version(extension_dir) do
    plugin_json_path =
      Path.join([extension_dir, "plugins", @plugin_slug, ".claude-plugin", "plugin.json"])

    case File.read(plugin_json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"version" => version}} -> version
          _ -> "0.1.0"
        end

      _ ->
        "0.1.0"
    end
  end

  defp push_to_github(extension_dir, version) do
    # Initialize git repo if needed
    unless File.exists?(Path.join(extension_dir, ".git")) do
      run_cmd("git", ["init", "-b", "main"], extension_dir)

      run_cmd(
        "git",
        ["remote", "add", "origin", "https://github.com/#{@github_repo}.git"],
        extension_dir
      )
    end

    # Commit and push
    run_cmd("git", ["add", "."], extension_dir)
    run_cmd("git", ["commit", "-m", "Release v#{version}", "--allow-empty"], extension_dir)
    run_cmd("git", ["tag", "-f", "v#{version}"], extension_dir)
    # Push branch and tag - ignore branch push errors since we only need the tag for releases
    run_cmd("git", ["push", "-u", "origin", "main", "--force"], extension_dir)
    run_cmd("git", ["push", "origin", "v#{version}", "--force"], extension_dir)
  end

  # sobelow_skip ["CI"]
  defp create_github_release(binary_path, _binary_name, version) do
    # Use GitHub CLI (gh) to create release and upload binary
    tag = "v#{version}"

    # Delete existing release if it exists (ignore errors)
    System.cmd("gh", ["release", "delete", tag, "--yes", "--repo", @github_repo],
      stderr_to_stdout: true
    )

    # Create new release and upload binary
    {output, exit_code} =
      System.cmd(
        "gh",
        [
          "release",
          "create",
          tag,
          binary_path,
          "--repo",
          @github_repo,
          "--title",
          "Release #{tag}",
          "--notes",
          "CodeMySpec CLI release #{tag}\n\nDownload the binary for your platform and run `./install.sh` to install."
        ],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      log("Warning: Failed to create GitHub release: #{output}")
    else
      log("GitHub release created: https://github.com/#{@github_repo}/releases/tag/#{tag}")
    end
  end

  # sobelow_skip ["CI"]
  defp run_cmd(cmd, args, dir) do
    {output, exit_code} = System.cmd(cmd, args, cd: dir, stderr_to_stdout: true)

    if exit_code != 0 do
      log("Warning: #{cmd} #{Enum.join(args, " ")} failed: #{output}")
    end

    {output, exit_code}
  end

  defp log(message) do
    IO.puts("--> [PackageExtension] #{message}")
  end

  # sobelow_skip ["Traversal"]
  defp copy_extension_files(source, dest) do
    # Intentionally NOT copying "bin" — the cms binary now lives in
    # ~/.codemyspec/bin/ (shared across plugin versions). Shipping a
    # 200MB stale copy inside every plugin release is a non-starter.
    for dir <- [".claude-plugin", "hooks", "agents", "skills", "knowledge"] do
      source_dir = Path.join(source, dir)
      dest_dir = Path.join(dest, dir)

      if File.exists?(source_dir) do
        File.cp_r!(source_dir, dest_dir)
      end
    end

    # marketplace.json belongs at the repo root in the new layout, not
    # inside the plugin dir. If it tagged along with .claude-plugin/,
    # drop it from the plugin's copy.
    stray_marketplace = Path.join([dest, ".claude-plugin", "marketplace.json"])
    if File.exists?(stray_marketplace), do: File.rm!(stray_marketplace)

    # Copy top-level files
    for file <- ["AGENTS.md"] do
      source_file = Path.join(source, file)
      dest_file = Path.join(dest, file)

      if File.exists?(source_file) do
        File.cp!(source_file, dest_file)
      end
    end
  end

  # Source tree is configured for dev (port 4004 so it can coexist with
  # the published binary on 4003). Walk the whole plugin tree and swap every
  # `4004` token to `4003` so the shipped plugin lands on the prod port.
  # Originally limited to `.claude-plugin/`, but skill markdown files (under
  # `skills/`) now contain server calls that also need rewriting.
  # NOTE: `match_dot: true` is REQUIRED. `.claude-plugin/` is a dotdir, and
  # `Path.wildcard/1` skips dot entries by default — without it, plugin.json and
  # the bin/hook,approve scripts (carrying `${CODEMYSPEC_PORT:-4004}`) silently
  # keep the dev port, shipping a prod plugin whose MCP server points at 4004.
  # sobelow_skip ["Traversal"]
  defp rewrite_dev_port(plugin_dest) do
    plugin_dest
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(fn path ->
      content = File.read!(path)

      if String.contains?(content, "4004") do
        File.write!(path, String.replace(content, "4004", "4003"))
      end
    end)
  end

  defp source_ext(%{os: :windows}), do: ".exe"
  defp source_ext(_), do: ""

  defp binary_name_for_target(target) do
    os =
      case target.os do
        :darwin -> "darwin"
        :linux -> "linux"
        :windows -> "windows"
      end

    arch =
      case target.cpu do
        :aarch64 -> "arm64"
        :x86_64 -> "x64"
      end

    if target.os == :windows do
      "#{@binary_name}-#{os}-#{arch}.exe"
    else
      "#{@binary_name}-#{os}-#{arch}"
    end
  end

  # sobelow_skip ["Traversal"]
  defp create_install_script(extension_dir) do
    script = ~S"""
    #!/bin/bash
    # CodeMySpec CLI Installer
    # Downloads the appropriate binary for your platform from GitHub Releases

    set -e

    REPO="Code-My-Spec/plugins"
    BINARY_NAME="cms"
    VERSION="${CMS_VERSION:-latest}"

    # Binary installs to shared ~/.codemyspec/bin/ so it survives plugin
    # upgrades. The plugin's hook + `cms self-update` read from the same path.
    CMS_HOME="$HOME/.codemyspec"
    BIN_DIR="$CMS_HOME/bin"
    mkdir -p "$BIN_DIR"

    # Colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'

    info()  { echo -e "${BLUE}${BOLD}>>>${NC} $1"; }
    ok()    { echo -e "${GREEN}${BOLD}>>>${NC} $1"; }
    err()   { echo -e "${RED}${BOLD}>>>${NC} $1"; }

    # Detect OS and architecture
    detect_platform() {
      OS="$(uname -s)"
      ARCH="$(uname -m)"

      case "$OS" in
        Darwin) OS="darwin" ;;
        Linux) OS="linux" ;;
        MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
        *) err "Unsupported OS: $OS"; exit 1 ;;
      esac

      case "$ARCH" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64) ARCH="x64" ;;
        *) err "Unsupported architecture: $ARCH"; exit 1 ;;
      esac

      if [ "$OS" = "windows" ]; then
        BINARY_FILE="${BINARY_NAME}-${OS}-${ARCH}.exe"
      else
        BINARY_FILE="${BINARY_NAME}-${OS}-${ARCH}"
      fi
    }

    # Get download URL from GitHub releases
    get_download_url() {
      if [ "$VERSION" = "latest" ]; then
        RELEASE_URL="https://api.github.com/repos/${REPO}/releases/latest"
      else
        RELEASE_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
      fi

      DOWNLOAD_URL=$(curl -s "$RELEASE_URL" | grep "browser_download_url.*${BINARY_FILE}" | cut -d '"' -f 4)

      if [ -z "$DOWNLOAD_URL" ]; then
        err "Could not find binary for ${BINARY_FILE}"
        echo "  Available binaries at: https://github.com/${REPO}/releases"
        exit 1
      fi
    }

    # Download and install binary
    install_binary() {
      mkdir -p "$BIN_DIR"

      info "Downloading ${BINARY_FILE}..."
      curl -fSL --progress-bar -o "$BIN_DIR/$BINARY_NAME" "$DOWNLOAD_URL"

      chmod +x "$BIN_DIR/$BINARY_NAME"
    }

    # Main
    main() {
      echo ""
      echo -e "${BOLD}CodeMySpec CLI Installer${NC}"
      echo ""

      detect_platform
      info "Platform: ${OS}-${ARCH}"

      if [ "$1" = "--dry-run" ]; then
        get_download_url
        echo "Would download from: $DOWNLOAD_URL"
        echo "Would install to: $BIN_DIR/$BINARY_NAME"
        exit 0
      fi

      get_download_url
      install_binary

      echo ""
      ok "Installation complete!"
      echo ""
      echo "  Next steps:"
      echo ""
      echo "  1. Install the plugin in Claude Code:"
      echo "     claude plugin install $SCRIPT_DIR"
      echo ""
      echo "  2. Open Claude Code in your Phoenix project and run:"
      echo "     /codemyspec:authenticate"
      echo ""
    }

    main "$@"
    """

    script_path = Path.join(extension_dir, "install.sh")
    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)
  end

  # sobelow_skip ["Traversal"]
  defp create_install_ps1(extension_dir) do
    script = ~S"""
    # CodeMySpec CLI Installer (Windows)
    # Downloads cms-windows-x64.exe from GitHub Releases and installs to
    # %USERPROFILE%\.codemyspec\bin\cms.exe so it survives plugin upgrades.
    #
    # Usage:
    #   iwr -useb https://raw.githubusercontent.com/Code-My-Spec/plugins/main/install.ps1 | iex
    #   .\install.ps1              # install latest
    #   .\install.ps1 -DryRun      # show what would happen
    #   $env:CMS_VERSION='v1.5.4'; .\install.ps1   # pin a version

    [CmdletBinding()]
    param(
      [switch]$DryRun
    )

    $ErrorActionPreference = 'Stop'

    $Repo       = 'Code-My-Spec/plugins'
    $BinaryBase = 'cms'
    $Version    = if ($env:CMS_VERSION) { $env:CMS_VERSION } else { 'latest' }

    $CmsHome = Join-Path $env:USERPROFILE '.codemyspec'
    $BinDir  = Join-Path $CmsHome 'bin'

    function Write-Info($msg) { Write-Host ">>> $msg" -ForegroundColor Blue }
    function Write-Ok($msg)   { Write-Host ">>> $msg" -ForegroundColor Green }
    function Write-Err($msg)  { Write-Host ">>> $msg" -ForegroundColor Red }

    function Get-PlatformBinaryName {
      $arch = (Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture
      # Architecture: 0=x86, 5=ARM, 9=x64, 12=ARM64
      switch ($arch) {
        9       { return "$BinaryBase-windows-x64.exe" }
        12      { Write-Err 'Windows ARM64 builds are not yet published.'; exit 1 }
        default { Write-Err "Unsupported architecture (Win32_Processor.Architecture=$arch)."; exit 1 }
      }
    }

    function Get-DownloadUrl([string]$binaryFile) {
      $releaseUrl = if ($Version -eq 'latest') {
        "https://api.github.com/repos/$Repo/releases/latest"
      } else {
        "https://api.github.com/repos/$Repo/releases/tags/$Version"
      }

      $headers = @{ 'User-Agent' = 'codemyspec-installer' }
      $resp = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
      $asset = $resp.assets | Where-Object { $_.name -eq $binaryFile } | Select-Object -First 1

      if (-not $asset) {
        Write-Err "Could not find $binaryFile in release $Version."
        Write-Host "  Available binaries at: https://github.com/$Repo/releases"
        exit 1
      }

      return $asset.browser_download_url
    }

    function Install-Binary([string]$url, [string]$dest) {
      New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

      Write-Info "Downloading $(Split-Path -Leaf $dest)..."
      Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }

    Write-Host ''
    Write-Host 'CodeMySpec CLI Installer' -ForegroundColor White
    Write-Host ''

    $binaryFile = Get-PlatformBinaryName
    Write-Info "Platform: windows-x64"

    $url  = Get-DownloadUrl $binaryFile
    $dest = Join-Path $BinDir 'cms.exe'

    if ($DryRun) {
      Write-Host "Would download from: $url"
      Write-Host "Would install to:    $dest"
      exit 0
    }

    Install-Binary $url $dest

    Write-Host ''
    Write-Ok 'Installation complete!'
    Write-Host ''
    Write-Host '  Next steps:'
    Write-Host ''
    Write-Host '  1. Install the plugin in Claude Code:'
    Write-Host '     claude plugin install <path-to-extension>'
    Write-Host ''
    Write-Host '  2. Open Claude Code in your Phoenix project and run:'
    Write-Host '     /codemyspec:authenticate'
    Write-Host ''
    """

    script_path = Path.join(extension_dir, "install.ps1")
    File.write!(script_path, script)
  end

  # sobelow_skip ["Traversal"]
  defp create_readme(extension_dir) do
    readme = readme_content()

    readme_path = Path.join(extension_dir, "README.md")
    File.write!(readme_path, readme)
  end

  defp readme_content do
    ~S"""
    # CodeMySpec — Claude Code Plugin Marketplace

    Specification-driven development plugins for Claude Code, powered by CodeMySpec.

    Today this marketplace ships one plugin — `codemyspec` — which turns user
    stories into working Phoenix code through a structured workflow: design
    architecture, write specifications, generate tests, then implement — all
    orchestrated by specialized AI agents that enforce clean architecture and
    maintain spec compliance.

    ## Installation

    In Claude Code:
    ```
    /plugin marketplace add Code-My-Spec/plugins
    /plugin install codemyspec@codemyspec
    ```

    The CLI binary auto-installs on first SessionStart.

    ## Layout

    - `.claude-plugin/marketplace.json` — marketplace manifest
    - `plugins/codemyspec/` — the CodeMySpec plugin source (skills, agents,
      hooks, install scripts)

    ## Getting Started

    Open Claude Code in your Phoenix project directory and run:

    ```
    /codemyspec:authenticate
    ```

    ## Skills

    All skills are accessed via `/codemyspec:<skill-name>` in Claude Code.

    ### Architecture & Design

    | Skill | Description |
    |-------|-------------|
    | `design-architecture` | Guided session to map user stories to bounded contexts and components |
    | `review-context` | Validate a context design and child specs against best practices |
    | `design-ui` | Interactive design system builder with DaisyUI, theme switcher, and live preview |

    ### Specification

    | Skill | Description |
    |-------|-------------|
    | `generate-spec` | Generate a component or context specification from stories and design rules |
    | `spec-context` | Generate specs for a context and all its child components via subagents |

    ### Implementation

    | Skill | Description |
    |-------|-------------|
    | `generate-test` | Create tests from spec assertions using TDD patterns |
    | `generate-code` | Implement a component from its spec and test file |
    | `implement-context` | Implement a full context with dependency ordering (schema -> repo -> service -> context) |
    | `develop-context` | Full lifecycle: spec -> test -> code for a context |
    | `develop-liveview` | Full lifecycle: spec -> test -> code for a LiveView |

    ### Testing & Orchestration

    | Skill | Description |
    |-------|-------------|
    | `write-bdd-specs` | Generate BDD tests for the next incomplete user story |
    | `manage-implementation` | Agentic loop: write BDD specs then implement until all stories pass |
    | `stop-implementation` | Disable agentic mode |

    ### Maintenance

    | Skill | Description |
    |-------|-------------|
    | `refactor-module` | Interactive refactoring: review code, discuss changes, update spec -> tests -> impl |
    | `sync` | Regenerate architecture views after git pulls or component changes |
    | `setup-project` | Verify Phoenix project prerequisites and initialize docs structure |

    ## How It Works

    CodeMySpec runs a local server (`bin/cms`) that provides:

    - **MCP Server** — Exposes architecture tools (component graph, dependency validation,
      story mapping) to Claude Code over HTTP
    - **Agent Task API** — Skills dispatch work to specialized agents (spec-writer,
      test-writer, code-writer) with role-specific prompts and tool access
    - **Hooks** — Intercepts file writes and test runs for real-time feedback

    The extension includes a **knowledge base** with framework guides for Phoenix
    LiveView, HEEx, Tailwind/DaisyUI, BDD testing, and clean architecture patterns.
    Agents reference these during generation for accurate, idiomatic code.

    ### Project Structure

    CodeMySpec creates and manages these directories in your Phoenix project:

    ```
    .code_my_spec/
    ├── spec/               # Component specifications (mirrors Elixir namespace)
    ├── rules/              # Design and test rules by component type
    ├── architecture/       # Dependency graph, namespace hierarchy, overview
    ├── status/             # Implementation checklists
    ├── knowledge/          # Project-specific research
    ├── plugin_knowledge/   # Framework knowledge (symlink to plugin)
    ├── design/             # Design system assets
    ├── issues/             # Known bugs and technical debt
    └── qa/                 # QA test results
    ```

    ## Requirements

    - macOS (Apple Silicon or Intel) or Linux
    - Claude Code CLI
    - Elixir 1.18+, Phoenix 1.8+, PostgreSQL
    - A CodeMySpec account (OAuth login via `cms login`)

    ## Troubleshooting

    ### macOS security warning

    If macOS blocks the binary, allow it in System Preferences > Security & Privacy.

    ### Permission denied

    ```bash
    chmod +x bin/cms
    ```

    ### Server not running

    Skills require the local server. Start it with:

    ```bash
    bin/cms server
    ```

    ## License

    MIT
    """
  end

  # sobelow_skip ["Traversal"]
  defp create_gitignore(extension_dir) do
    # The cms binary now lives at ~/.codemyspec/bin/cms (shared across
    # plugin versions), not inside the plugin tree. Nothing to ignore
    # in the repo itself — keep a placeholder .gitignore for consumers.
    gitignore = """
    # Reserved — binary installs to ~/.codemyspec/bin/cms outside this tree.
    """

    gitignore_path = Path.join(extension_dir, ".gitignore")
    File.write!(gitignore_path, gitignore)
  end

  # sobelow_skip ["Traversal"]
  defp create_marketplace_json(extension_dir, plugin_dest) do
    plugin_json_path = Path.join([plugin_dest, ".claude-plugin", "plugin.json"])

    {description, version} =
      case File.read(plugin_json_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{} = json} ->
              {Map.get(json, "description", "CodeMySpec plugins for Claude Code"),
               Map.get(json, "version", "0.1.0")}

            _ ->
              {"CodeMySpec plugins for Claude Code", "0.1.0"}
          end

        _ ->
          {"CodeMySpec plugins for Claude Code", "0.1.0"}
      end

    marketplace = %{
      "$schema" => "https://anthropic.com/claude-code/marketplace.schema.json",
      "name" => "codemyspec",
      "owner" => %{
        "name" => "CodeMySpec",
        "url" => "https://codemyspec.com"
      },
      "metadata" => %{
        "description" => "CodeMySpec plugins for Claude Code"
      },
      "plugins" => [
        %{
          "name" => @plugin_slug,
          "source" => "./plugins/#{@plugin_slug}",
          "description" => description,
          "version" => version
        }
      ]
    }

    marketplace_dir = Path.join(extension_dir, ".claude-plugin")
    File.mkdir_p!(marketplace_dir)

    File.write!(
      Path.join(marketplace_dir, "marketplace.json"),
      Jason.encode!(marketplace, pretty: true)
    )
  end
end

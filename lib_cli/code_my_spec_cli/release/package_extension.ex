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
    source_extension = Path.join(app_path, "plugins/claude")

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
    log("Rewrote dev values (4004 -> 4003, dev.codemyspec.com -> codemyspec.com)")

    create_marketplace_json(extension_dir, plugin_dest)
    log("Created marketplace.json")

    create_install_script(extension_dir)
    log("Created install script")

    # No Windows install.ps1 here anymore: Windows installs are a standalone,
    # plugin-decoupled Shawl service (installers/windows/install.ps1). The
    # plugin only talks to the running server on its port.

    create_readme(extension_dir)
    log("Created README")

    create_gitignore(extension_dir)

    # The Antigravity and Codex ports of the plugin ship in the same release
    # repo, under antigravity/ and codex/. Source layout: plugins/<vendor>/,
    # siblings of plugins/claude/.
    source_antigravity = Path.join(Path.dirname(source_extension), "antigravity")
    package_antigravity_files(source_antigravity, extension_dir)

    source_codex = Path.join(Path.dirname(source_extension), "codex")
    package_codex_files(source_codex, extension_dir)

    %{extension_dir: extension_dir, plugin_dest: plugin_dest}
  end

  @doc """
  Packages the Antigravity plugin (`plugins/antigravity/`) into
  `<extension_dir>/antigravity/#{@plugin_slug}/` with the same dev→prod
  port rewrite as the Claude plugin. Users install it with
  `agy plugin install ./antigravity/#{@plugin_slug}` from a checkout, or by
  copying that directory into `.agents/plugins/` / `~/.gemini/config/plugins/`.
  """
  # sobelow_skip ["Traversal"]
  def package_antigravity_files(source_antigravity, extension_dir) do
    if File.dir?(source_antigravity) do
      antigravity_dest = Path.join([extension_dir, "antigravity", @plugin_slug])

      File.rm_rf!(antigravity_dest)
      File.mkdir_p!(antigravity_dest)

      File.cp_r!(source_antigravity, antigravity_dest)
      log("Copied Antigravity plugin into antigravity/#{@plugin_slug}/")

      rewrite_dev_port(antigravity_dest)
      log("Rewrote Antigravity dev values (4004 -> 4003, dev.codemyspec.com -> codemyspec.com)")

      # cp_r preserves modes, but the hook script MUST be executable —
      # a silent chmod loss would make every hook a no-op.
      hook_script = Path.join([antigravity_dest, "bin", "ag-hook.sh"])
      if File.exists?(hook_script), do: File.chmod!(hook_script, 0o755)

      create_antigravity_install_script(extension_dir)
      log("Created install-antigravity.sh")
    else
      log("Antigravity plugin source not found at #{source_antigravity} — skipping")
    end
  end

  # Antigravity has no marketplace-by-git mechanism — users either clone this
  # repo and `agy plugin install` a path, or run this one-liner:
  #
  #   curl -fsSL https://raw.githubusercontent.com/Code-My-Spec/plugins/main/install-antigravity.sh | bash
  #
  # The script downloads the repo tarball, extracts the Antigravity plugin,
  # and copies it into Antigravity's global plugin locations.
  # sobelow_skip ["Traversal"]
  defp create_antigravity_install_script(extension_dir) do
    script = ~S"""
    #!/bin/bash
    # Install the CodeMySpec plugin for Google Antigravity.
    #
    # Downloads the plugin from the Code-My-Spec/plugins repo and copies it into
    # Antigravity's global plugin directory (and the Antigravity CLI's, if the
    # CLI is present). Safe to re-run — each run replaces the installed copy.
    #
    # macOS / Linux only. Requires: curl, tar.
    set -euo pipefail

    REPO="Code-My-Spec/plugins"
    PLUGIN_SUBDIR="antigravity/codemyspec"
    GLOBAL_DEST="$HOME/.gemini/config/plugins/codemyspec"
    CLI_HOME="$HOME/.gemini/antigravity-cli"
    CLI_DEST="$CLI_HOME/plugins/codemyspec"

    BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
    info() { echo -e "${BLUE}${BOLD}>>>${NC} $1"; }
    ok()   { echo -e "${GREEN}${BOLD}>>>${NC} $1"; }
    err()  { echo -e "${RED}${BOLD}>>>${NC} $1"; }

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    info "Downloading CodeMySpec Antigravity plugin..."
    curl -fsSL "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" \
      | tar -xz -C "$TMP" --strip-components=3 "plugins-main/${PLUGIN_SUBDIR}"

    if [ ! -f "$TMP/plugin.json" ]; then
      err "Download failed — plugin.json not found in archive"
      exit 1
    fi

    install_to() {
      local dest="$1"
      rm -rf "$dest"
      mkdir -p "$(dirname "$dest")"
      cp -R "$TMP" "$dest"
      chmod +x "$dest/bin/ag-hook.sh"
      ok "Installed to $dest"
    }

    install_to "$GLOBAL_DEST"

    # Stage into the Antigravity CLI's plugin directory too, if the CLI is set up.
    if [ -d "$CLI_HOME" ]; then
      install_to "$CLI_DEST"
    fi

    echo
    ok "CodeMySpec plugin for Antigravity installed."
    echo
    echo "  Requires the cms server (skills, hooks, and MCP talk to it):"
    echo "    brew install Code-My-Spec/tap/codemyspec && brew services start codemyspec"
    echo
    echo "  Restart Antigravity (or reload plugins) to pick it up."
    """

    script_path = Path.join(extension_dir, "install-antigravity.sh")
    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)
  end

  @doc """
  Packages the Codex plugin (`plugins/codex/`) into
  `<extension_dir>/codex/#{@plugin_slug}/` with the same dev→prod port
  rewrite, and writes the Codex marketplace catalog at
  `.agents/plugins/marketplace.json` so users can install with
  `codex plugin marketplace add #{@github_repo}`.
  """
  # sobelow_skip ["Traversal"]
  def package_codex_files(source_codex, extension_dir) do
    if File.dir?(source_codex) do
      codex_dest = Path.join([extension_dir, "codex", @plugin_slug])

      File.rm_rf!(codex_dest)
      File.mkdir_p!(codex_dest)

      File.cp_r!(source_codex, codex_dest)
      log("Copied Codex plugin into codex/#{@plugin_slug}/")

      rewrite_dev_port(codex_dest)
      log("Rewrote Codex dev values (4004 -> 4003, dev.codemyspec.com -> codemyspec.com)")

      hook_script = Path.join([codex_dest, "bin", "hook"])
      if File.exists?(hook_script), do: File.chmod!(hook_script, 0o755)

      create_codex_marketplace_json(extension_dir, codex_dest)
      log("Created Codex marketplace catalog (.agents/plugins/marketplace.json)")
    else
      log("Codex plugin source not found at #{source_codex} — skipping")
    end
  end

  # sobelow_skip ["Traversal"]
  defp create_codex_marketplace_json(extension_dir, codex_dest) do
    manifest_path = Path.join([codex_dest, ".codex-plugin", "plugin.json"])

    description =
      case File.read(manifest_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"description" => description}} -> description
            _ -> "CodeMySpec plugin for Codex"
          end

        _ ->
          "CodeMySpec plugin for Codex"
      end

    marketplace = %{
      "name" => "codemyspec",
      "plugins" => [
        %{
          "name" => @plugin_slug,
          "description" => description,
          "source" => %{
            "source" => "git-subdir",
            "url" => "https://github.com/#{@github_repo}.git",
            "path" => "./codex/#{@plugin_slug}",
            "ref" => "main"
          },
          "policy" => %{
            "installation" => "AVAILABLE",
            "authentication" => "ON_INSTALL"
          },
          "category" => "Developer Tools"
        }
      ]
    }

    marketplace_dir = Path.join([extension_dir, ".agents", "plugins"])
    File.mkdir_p!(marketplace_dir)

    File.write!(
      Path.join(marketplace_dir, "marketplace.json"),
      Jason.encode!(marketplace, pretty: true)
    )
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

  # Source tree is configured for dev (port 4004, dev.codemyspec.com) so it can
  # coexist with the published binary (port 4003, codemyspec.com). Walk the
  # whole plugin tree and swap every dev token to its prod counterpart.
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

      rewritten =
        content
        |> String.replace("4004", "4003")
        |> String.replace("dev.codemyspec.com", "codemyspec.com")

      if rewritten != content, do: File.write!(path, rewritten)
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
    # Auto-install of a single binary is gone — cms ships as a plain OTP
    # release packaged per platform. install.sh points at the platform
    # installer (brew on macOS, the MSI on Windows).
    script = ~S"""
    #!/bin/bash
    echo ""
    echo "Install CodeMySpec with your platform's installer:"
    echo ""
    echo "  macOS:    brew install Code-My-Spec/tap/codemyspec"
    echo "  Windows:  download cms-setup-x64.msi from the latest release and run it"
    echo ""
    echo "  Releases: https://github.com/Code-My-Spec/plugins/releases"
    echo ""
    """

    script_path = Path.join(extension_dir, "install.sh")
    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)
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

    CodeMySpec is two pieces: the `cms` server, a local background OS service that
    hosts the MCP tools and architecture graph, and the Claude Code plugin that
    drives it. Install the server first, then the plugin.

    ### 1. Install the `cms` server

    macOS (Apple Silicon):
    ```
    brew install Code-My-Spec/tap/codemyspec
    brew services start codemyspec
    ```

    Windows (x64): download `cms-setup-x64.msi` from the latest release and run it,
    or from an elevated PowerShell:
    ```
    iwr -useb https://raw.githubusercontent.com/Code-My-Spec/plugins/main/install.ps1 -OutFile install.ps1; .\install.ps1
    ```

    Either installer registers `cms` as a background service (launchd via `brew
    services` on macOS, a Shawl-wrapped service via the MSI) listening on
    http://localhost:4003, and puts `cms` and `cms-mcp-relay` on your PATH.

    ### 2. Install the plugin

    In Claude Code:
    ```
    /plugin marketplace add Code-My-Spec/plugins
    /plugin install codemyspec@codemyspec
    ```

    ### Google Antigravity

    One-liner (installs into `~/.gemini/config/plugins/`, plus the Antigravity
    CLI's plugin directory if present):

    ```
    curl -fsSL https://raw.githubusercontent.com/Code-My-Spec/plugins/main/install-antigravity.sh | bash
    ```

    Or manually: the plugin lives under `antigravity/codemyspec/` — with this
    repo checked out, `agy plugin install ./antigravity/codemyspec`, or copy
    that directory into your workspace's `.agents/plugins/` (workspace-scoped)
    or `~/.gemini/config/plugins/` (global). The `cms` server install from
    step 1 is required either way.

    ### OpenAI Codex

    The Codex port lives under `codex/codemyspec/`, and this repo doubles as
    a Codex plugin marketplace:

    ```
    codex plugin marketplace add Code-My-Spec/plugins
    ```

    Then install `codemyspec` from the `/plugins` picker, and trust its hooks
    via `/hooks`. The `cms` server install from step 1 is required.

    ## Layout

    - `.claude-plugin/marketplace.json` — Claude Code marketplace manifest
    - `.agents/plugins/marketplace.json` — Codex marketplace catalog
    - `plugins/codemyspec/` — the CodeMySpec plugin source (skills, agents,
      hooks, install scripts)
    - `antigravity/codemyspec/` — the Google Antigravity port (skills, agents,
      rules, hooks, MCP config)
    - `codex/codemyspec/` — the OpenAI Codex port (skills, hooks, MCP config)

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

# Homebrew formula for CodeMySpec (macOS).
#
# Installs the plain `mix release` tarball — a self-contained OTP release (ERTS
# + start.boot on disk, no runtime extraction). `brew services` registers it
# with launchd, so there's no Shawl and no MSI on macOS.
#
# __CMS_TAG__ / __CMS_VERSION__ / __DARWIN_SHA256__ are templated by the
# release workflow (release-extension.yml) into the published copy.
class Codemyspec < Formula
  desc "CodeMySpec local server (Phoenix + MCP) on port 4003"
  homepage "https://codemyspec.com"
  version "__CMS_VERSION__"
  url "https://github.com/Code-My-Spec/plugins/releases/download/__CMS_TAG__/cms-darwin-arm64.tar.gz"
  sha256 "__DARWIN_SHA256__"

  def install
    # The tarball extracts to bin/, lib/, releases/, erts-* at top level.
    libexec.install Dir["*"]
    # Expose the release launcher as `cms`. A wrapper (not a symlink) so the
    # launcher resolves RELEASE_ROOT from libexec, not the bin symlink.
    (bin/"cms").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/code_my_spec_cli" "$@"
    SH
    chmod 0755, bin/"cms"

    # cms-mcp-relay: the standalone Go stdio<->HTTP MCP bridge that Claude Code
    # spawns for the plugin's local MCP server. Self-contained (no RELEASE_ROOT),
    # so a plain symlink into bin/ is enough.
    bin.install_symlink libexec/"bin/cms-mcp-relay"
  end

  service do
    # `cms start` is the mix-release launcher's foreground boot command — it
    # runs the OTP app in the foreground for launchd (via `brew services`) to
    # supervise; keep_alive restarts it on exit. (`server` is NOT a release
    # launcher command, only a dev/`mix` alias.) The old `cms start` daemon
    # double-fork was already inert on the plain release and has been removed.
    run [opt_bin/"cms", "start"]
    keep_alive true
    log_path var/"log/codemyspec.log"
    error_log_path var/"log/codemyspec.log"
  end

  test do
    assert_match version.to_s,
      shell_output("#{bin}/cms eval 'IO.puts Application.spec(:code_my_spec, :vsn)'")
  end
end

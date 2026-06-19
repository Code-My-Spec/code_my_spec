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
  end

  service do
    # Run the BEAM in the foreground; launchd (via `brew services`) is the
    # supervisor — keep_alive restarts it on exit. No `cms start` daemon
    # double-fork: that exited immediately and left launchd respawning a
    # process that wasn't the real server.
    run [opt_bin/"cms", "server"]
    keep_alive true
    log_path var/"log/codemyspec.log"
    error_log_path var/"log/codemyspec.log"
  end

  test do
    assert_match version.to_s,
      shell_output("#{bin}/cms eval 'IO.puts Application.spec(:code_my_spec, :vsn)'")
  end
end

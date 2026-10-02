# Homebrew formula for the CodeMySpec desktop build (macOS, bb8bc042).
#
# The server and the light harness in one release (`MIX_ENV=desktop mix release
# code_my_spec`): the app on http://localhost:4000, hooks on :4004. It needs a
# local Postgres with pgvector; it creates and migrates its own database on
# boot.
#
# __CMS_TAG__ / __CMS_VERSION__ / __DARWIN_SHA256__ are templated by the
# release workflow into the published copy, as in codemyspec.rb.
class CodemyspecDesktop < Formula
  desc "CodeMySpec desktop: server and harness on localhost"
  homepage "https://codemyspec.com"
  version "__CMS_VERSION__"
  url "https://github.com/Code-My-Spec/plugins/releases/download/__CMS_TAG__/codemyspec-desktop-darwin-arm64.tar.gz"
  sha256 "__DARWIN_SHA256__"

  depends_on "pgvector"
  depends_on "postgresql@17"

  conflicts_with "codemyspec", because: "both run a harness on port 4004"

  def install
    libexec.install Dir["*"]
    # A wrapper, not a symlink, so the launcher resolves RELEASE_ROOT from libexec.
    (bin/"codemyspec").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/code_my_spec" "$@"
    SH
    chmod 0755, bin/"codemyspec"
  end

  service do
    run [opt_bin/"codemyspec", "start"]
    # Not a browser on every login and every restart; `codemyspec start` in a
    # terminal still opens one.
    environment_variables CMS_NO_BROWSER: "1"
    keep_alive true
    log_path var/"log/codemyspec-desktop.log"
    error_log_path var/"log/codemyspec-desktop.log"
  end

  def caveats
    <<~EOS
      CodeMySpec needs Postgres running (pgvector is installed into it):

        brew services start postgresql@17

      It connects as you and creates its database (code_my_spec_desktop) on
      first start; set DATABASE_URL to use another. Then:

        brew services start codemyspec-desktop

      and open http://localhost:4000.
    EOS
  end

  test do
    assert_match version.to_s,
      shell_output("#{bin}/codemyspec eval 'IO.puts Application.spec(:code_my_spec, :vsn)'")
  end
end

defmodule CodeMySpec.Generators.DeployArtifactsTest do
  @moduledoc """
  What a generated project has to carry before it can deploy at all.

  Every assertion here stands for a failure seen on a real box. The release
  reads `DATABASE_URL` and `SECRET_KEY_BASE` from its environment in
  `runtime.exs`, and the only place they exist is inside
  `envs/<env>.enc.env` — so each path that starts the release has to decrypt
  first, and the image has to carry both the ciphertext and the tool.

  Missing any one of them fails the same way and reads as something else:
  the app raises "environment variable DATABASE_URL is missing", kamal waits
  out its 30s health timeout, and the deploy reports a failed traffic swap —
  naming the swap, which was not the thing that was wrong.

  `boot` and `migrate` are asserted separately on purpose. They drifted apart
  once: the decryption was written for the serving path and `migrate` was
  left running the release raw, so every migration died and no generated
  project could complete a deploy.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Generators.DeployArtifacts

  @opts [app: "my_app", host: "example.com", registry: "ghcr.io", owner: "acme"]

  defp file(path) do
    {^path, body} = Enum.find(DeployArtifacts.files(@opts), &(elem(&1, 0) == path))
    body
  end

  describe "the release overlays" do
    test "boot decrypts the environment before starting the app" do
      body = file("rel/overlays/bin/boot")

      assert body =~ ~s(exec sops exec-env "$ENV_FILE" "./bin/my_app start")
      assert body =~ ~s(ENV_FILE="envs/${ENV_NAME}.enc.env")
    end

    test "migrate decrypts the environment before running migrations" do
      body = file("rel/overlays/bin/migrate")

      assert body =~ ~s(exec sops exec-env "$ENV_FILE" "./bin/my_app eval MyApp.Release.migrate")
      assert body =~ ~s(ENV_FILE="envs/${ENV_NAME}.enc.env")
    end

    test "both name a missing key and a missing env file rather than letting sops answer" do
      # sops fails an absent key with "no identity matched any of the
      # recipients", which reads as the file being encrypted to somebody else.
      for path <- ["rel/overlays/bin/boot", "rel/overlays/bin/migrate"] do
        body = file(path)

        assert body =~ ~s(if [ -z "${SOPS_AGE_KEY:-}" ]; then), path
        assert body =~ ~s(if [ ! -f "$ENV_FILE" ]; then), path
      end
    end

    test "both take the environment from APP_ENV, so one image serves either" do
      for path <- ["rel/overlays/bin/boot", "rel/overlays/bin/migrate"] do
        assert file(path) =~ ~s(ENV_NAME="${APP_ENV:-prod}"), path
      end
    end
  end

  describe "the Dockerfile" do
    test "starts the app through boot, not through the release directly" do
      assert file("Dockerfile") =~ ~s(CMD ["bin/boot"])
      refute file("Dockerfile") =~ ~s(CMD ["bin/my_app", "start"])
    end

    test "carries the encrypted environments into the image" do
      assert file("Dockerfile") =~ "COPY envs rel/overlays/envs"
    end

    test "carries sops into the runtime stage, fetched in the builder" do
      body = file("Dockerfile")

      assert body =~ "COPY --from=builder /usr/local/bin/sops /usr/local/bin/sops"
      assert body =~ "sops-v${SOPS_VERSION}.linux.$(dpkg --print-architecture)"
    end

    # Confirmed live against broken_oaths: this image's git/curl breaks a
    # git-sourced mix dependency's smart-http fetch over HTTP/2 against
    # GitHub — "could not read Username for 'https://github.com'" /
    # "expected flush after ref listing", neither a real credential or
    # protocol problem. A plain curl GET to the same URL succeeds; forcing
    # HTTP/1.1 clones the same repo cleanly every time HTTP/2 fails. Every
    # generated project carries this risk on its first build, since
    # heroicons via `github:` is phx.new's own default dependency.
    test "forces HTTP/1.1 for git before fetching mix deps, so a git-sourced dependency's fetch does not break over HTTP/2" do
      body = file("Dockerfile")
      fix = "RUN git config --global http.version HTTP/1.1"

      assert body =~ fix

      fix_index = :binary.match(body, fix) |> elem(0)
      deps_get_index = :binary.match(body, "RUN mix deps.get") |> elem(0)

      assert fix_index < deps_get_index,
             "git's http.version must be set before mix deps.get runs, not after"
    end
  end

  describe "the kamal config" do
    defp config(path, opts) do
      {^path, body} = Enum.find(DeployArtifacts.files(opts), &(elem(&1, 0) == path))
      body
    end

    test "logs into ghcr for a project that was never given its own registry" do
      body = config("config/deploy.yml", @opts)

      assert body =~ "server: ghcr.io"
    end

    # Found live onboarding a real project (MarketMySpec) onto a
    # `:server`-provisioned self-hosted registry: this used to hardcode
    # `server: ghcr.io` regardless of what `registry` the image itself was
    # built from, so a project on its own registry got a config that could
    # never authenticate against it. The credential env var *names* stay the
    # same either way — `Deploy.run/3`'s `KAMAL_REGISTRY_USERNAME`/`PASSWORD`
    # supply whichever registry's real credential at deploy time — only the
    # host Kamal logs into was ever wrong here.
    test "logs into the registry the image actually came from" do
      opts = Keyword.put(@opts, :registry, "localhost:5000")

      for path <- ["config/deploy.yml", "config/deploy.uat.yml"] do
        body = config(path, opts)

        assert body =~ "server: localhost:5000", path
        refute body =~ "ghcr.io", path
        assert body =~ "- KAMAL_REGISTRY_USERNAME", path
        assert body =~ "- KAMAL_REGISTRY_PASSWORD", path
        assert body =~ "image: localhost:5000/acme/my_app", path
      end
    end

    test "an explicit :image wins over the owner/app composition" do
      opts = Keyword.merge(@opts, registry: "localhost:5000", image: "localhost:5000/sam-s-app")

      body = config("config/deploy.yml", opts)

      assert body =~ "image: localhost:5000/sam-s-app"
      refute body =~ "acme"
    end

    # `Deploy.run/3`'s own `script_env/1` already sets `CMS_SSH_KEY_PATH` —
    # this is the half that had gone nowhere: nothing in the generated config
    # ever read it, so kamal fell back to offering every identity the ambient
    # agent held, and a box with the default `MaxAuthTries 6` disconnected
    # before ever reaching the right one. Found live adopting broken_oaths,
    # but the template is shared, so a fresh `cms_new` project carried the
    # identical gap.
    test "reads the deploy ssh key from CMS_SSH_KEY_PATH, in both environments" do
      for path <- ["config/deploy.yml", "config/deploy.uat.yml"] do
        body = config(path, @opts)

        assert body =~ ~s(<% if ENV["CMS_SSH_KEY_PATH"] %>), path
        assert body =~ ~s(keys: ["<%= ENV["CMS_SSH_KEY_PATH"] %>"]), path
        assert body =~ "keys_only: true", path
      end
    end

    # ERB, not Elixir interpolation — ordinary string assertions cannot tell
    # a tag that renders from one kamal itself would refuse to parse. Real
    # `kamal config` is what proved the earlier hand-written attempt correct
    # (and caught a first draft that produced invalid YAML under `keys_only`'s
    # indentation) — this is that same proof, kept.
    test "kamal itself parses the ssh block into keys_only when the env var is set" do
      {:ok, dir} = Briefly.create(directory: true)
      path = Path.join(dir, "deploy.yml")
      # Kamal validates the whole config; a fresh project's own generated
      # `files/1` output does not include `builder:`, so one is added here
      # purely to let `kamal config` finish resolving without raising on an
      # unrelated, already-required field this test has nothing to say about.
      File.write!(path, config("config/deploy.yml", @opts) <> "\nbuilder:\n  arch: amd64\n")

      {output, 0} =
        System.cmd("kamal", ["config", "--config-file", path],
          env: [{"CMS_SSH_KEY_PATH", "/tmp/example_key"}],
          stderr_to_stdout: true
        )

      assert output =~ ":keys_only: true"
      assert output =~ ~s(- "/tmp/example_key")
    end

    test "kamal falls back to its own default ssh behavior when the env var is unset" do
      {:ok, dir} = Briefly.create(directory: true)
      path = Path.join(dir, "deploy.yml")
      File.write!(path, config("config/deploy.yml", @opts) <> "\nbuilder:\n  arch: amd64\n")

      # `nil`, not `""` — Ruby's `if` treats an empty string as truthy, and
      # `Deploy.run/3`'s own `script_env/1` never sends one either
      # (`is_binary(value) and value != ""` keeps a blank value out of the
      # subprocess env entirely), so unset is the only shape this has to
      # answer for.
      {output, 0} =
        System.cmd("kamal", ["config", "--config-file", path],
          env: [{"CMS_SSH_KEY_PATH", nil}],
          stderr_to_stdout: true
        )

      refute output =~ ":keys_only: true"
    end
  end

  describe "bin/backup" do
    # Confirmed live, on every project the shared postgres box has ever
    # served: the app's own role cannot CREATE/DROP DATABASE for restore-
    # verification's scratch copy — Database.serve/3 deliberately never
    # grants CREATEDB to it, since that role authenticates every live
    # request and a standing ability to create databases is not a
    # privilege a compromised request should inherit. A second, narrower
    # role gets it instead, delivered as CMS_RESTORE_ADMIN_URL alongside
    # DATABASE_URL in the same encrypted env.
    test "restores using the dedicated restore-verification credential, not DATABASE_URL" do
      body = file("bin/backup")

      assert body =~ "admin_url=\"$(libpq_url \"$CMS_RESTORE_ADMIN_URL\")\""
      refute body =~ "admin_url=\"$(libpq_url \"${DATABASE_URL%/*}/postgres\")\""
    end

    test "names the missing credential explicitly rather than failing on an empty connection string" do
      assert file("bin/backup") =~ "\"${CMS_RESTORE_ADMIN_URL:?"
    end
  end

  # Real shelling out, same reasoning `Deploy.run/3`'s own tests give for
  # doing this rather than asserting on the string content: a script this
  # important is worth running for real, not just grepping.
  describe "bin/deploy" do
    setup do
      {:ok, tmp} = Briefly.create(directory: true)
      bin_dir = Path.join(tmp, "bin")
      File.mkdir_p!(bin_dir)

      script_path = Path.join(bin_dir, "deploy")
      File.write!(script_path, file("bin/deploy"))
      File.chmod!(script_path, 0o755)

      fake_bin_dir = Path.join(tmp, "fakebin")
      File.mkdir_p!(fake_bin_dir)

      %{tmp: tmp, script_path: script_path, fake_bin_dir: fake_bin_dir}
    end

    defp fake_command(dir, name, script_body) do
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\n" <> script_body)
      File.chmod!(path, 0o755)
    end

    # `fake_bin_dir` first, so a fake `kamal`/`gh` shadows anything real —
    # the real system `PATH` stays behind it so `git` (never faked below)
    # still works, and so a phase that reaches for something genuinely
    # absent (real `kamal`, not installed here) fails loudly with "command
    # not found" rather than silently succeeding against nothing.
    defp run_deploy(script_path, fake_bin_dir, args, env) do
      System.cmd(script_path, args,
        cd: Path.dirname(Path.dirname(script_path)),
        env: [{"PATH", "#{fake_bin_dir}:#{System.get_env("PATH")}"}] ++ env,
        stderr_to_stdout: true
      )
    end

    # The whole point: setup already built and pushed this exact image, so
    # asking git or GitHub anything here would be answering a question that
    # was already answered, in a way that could disagree with it. Proven by
    # the script's own control flow rather than by forbidding git/gh
    # outright: `case "$PHASE" in migrate) ... ;; esac` cannot reach the
    # branch that calls them at all.
    test "migrate calls kamal directly, never git or GitHub", %{
      script_path: script_path,
      fake_bin_dir: fake_bin_dir
    } do
      log = Path.join(fake_bin_dir, "kamal.log")
      fake_command(fake_bin_dir, "kamal", "echo \"$*\" >> #{log}\n")

      assert {_output, 0} =
               run_deploy(script_path, fake_bin_dir, ["migrate", "prod"], [
                 {"CMS_IMAGE", "localhost:5000/market-my-spec:abc123"},
                 {"SOPS_AGE_KEY", "test-key"}
               ])

      logged = File.read!(log)
      assert logged =~ "app exec --config-file config/deploy.yml --version abc123"
      assert logged =~ "SOPS_AGE_KEY:test-key"
      refute logged =~ "deploy --config"
    end

    test "swap deploys the exact version migrate just ran against", %{
      script_path: script_path,
      fake_bin_dir: fake_bin_dir
    } do
      log = Path.join(fake_bin_dir, "kamal.log")
      fake_command(fake_bin_dir, "kamal", "echo \"$*\" >> #{log}\n")

      assert {_output, 0} =
               run_deploy(script_path, fake_bin_dir, ["swap", "uat"], [
                 {"CMS_IMAGE", "localhost:5000/market-my-spec:abc123"}
               ])

      logged = File.read!(log)
      assert logged =~ "deploy --config-file config/deploy.uat.yml --version abc123"
      refute logged =~ "app exec"
    end

    test "a phase called without CMS_IMAGE falls back to the checkout's own HEAD", %{
      tmp: tmp,
      script_path: script_path,
      fake_bin_dir: fake_bin_dir
    } do
      {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)

      {_, 0} =
        System.cmd(
          "git",
          ["-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "--allow-empty", "-q", "-m", "x"],
          cd: tmp
        )

      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
      head = String.trim(head)

      log = Path.join(fake_bin_dir, "kamal.log")
      fake_command(fake_bin_dir, "kamal", "echo \"$*\" >> #{log}\n")

      assert {_output, 0} = run_deploy(script_path, fake_bin_dir, ["migrate", "prod"], [])

      assert File.read!(log) =~ "--version #{head}"
    end

    # The original, single-invocation flow a human runs by hand — unchanged
    # by any of the above, since setup never calls this branch.
    test "a bare environment argument still pushes, waits for CI, then runs both phases", %{
      tmp: tmp,
      script_path: script_path,
      fake_bin_dir: fake_bin_dir
    } do
      {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp)

      {_, 0} =
        System.cmd(
          "git",
          ["-c", "user.email=a@b.c", "-c", "user.name=a", "commit", "--allow-empty", "-q", "-m", "x"],
          cd: tmp
        )

      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
      head = String.trim(head)

      # A fake `git remote`/push target so `git push origin HEAD` has
      # somewhere real to push to instead of failing on a remote that does
      # not exist — this test is about what the script does after that
      # succeeds, not about proving push itself works.
      {:ok, bare} = Briefly.create(directory: true)
      {_, 0} = System.cmd("git", ["init", "-q", "--bare"], cd: bare)
      {_, 0} = System.cmd("git", ["remote", "add", "origin", bare], cd: tmp)

      log = Path.join(fake_bin_dir, "calls.log")
      fake_command(fake_bin_dir, "gh", "echo \"gh $*\" >> #{log}; echo 999\n")
      fake_command(fake_bin_dir, "kamal", "echo \"kamal $*\" >> #{log}\n")

      assert {_output, 0} = run_deploy(script_path, fake_bin_dir, ["prod"], [])

      logged = File.read!(log)
      assert logged =~ "gh run list --commit #{head}"
      assert logged =~ "gh run watch --exit-status 999"
      assert logged =~ "kamal app exec --config-file config/deploy.yml --version #{head}"
      assert logged =~ "kamal deploy --config-file config/deploy.yml --version #{head} --skip-push"

      {branches, 0} = System.cmd("git", ["branch", "-a"], cd: bare)
      assert branches =~ "main" or branches =~ "master"
    end
  end

  describe "the runtime config" do
    test "excludes the health path by path, not by hostname" do
      # `Plug.SSL.validate_exclude!/1` maps a bare binary to `{:hosts, [binary]}`,
      # so `exclude: ["/health"]` excluded a host named "/health" — which matches
      # nothing, leaving the proxy's probe redirected and the swap never done.
      body = file("config/runtime.exs")

      assert body =~ ~s(paths: ["/health"])
      assert body =~ ~s(hosts: ["localhost", "127.0.0.1"])
    end
  end
end

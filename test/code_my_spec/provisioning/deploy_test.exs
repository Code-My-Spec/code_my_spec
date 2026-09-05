defmodule CodeMySpec.Provisioning.DeployTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Deploy
  alias CodeMySpec.Provisioning.Deploy.Result

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    %{env: Environment.new(:local, tmp)}
  end

  # A script that records the phase it was called with and exits how the test
  # tells it to. Real shelling out through Environments.cmd/4, so the ordering
  # under test is the ordering that actually happens.
  defp deploy_script(dir, opts) do
    migrate_exit = Keyword.get(opts, :migrate_exit, 0)
    swap_exit = Keyword.get(opts, :swap_exit, 0)
    # What `bin/deploy` prints when it finds no env files on the host — the
    # only signal that nothing has ever booted there.
    first_deploy = (Keyword.get(opts, :first_deploy, false) && "first_deploy=1") || ""
    path = Path.join(dir, "fake_deploy")

    File.write!(path, """
    #!/bin/sh
    echo "$1 $2 #{first_deploy}"
    case "$1" in
      migrate) exit #{migrate_exit} ;;
      swap) exit #{swap_exit} ;;
    esac
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Records the environment it was handed, so a test can assert on the contract
  # between setup and the deploy script rather than on the script's exit code.
  defp recording_script(dir) do
    path = Path.join(dir, "recording_deploy")
    log = Path.join(dir, "deploy_env.log")

    File.write!(path, """
    #!/bin/sh
    echo "$1 CMS_IMAGE=${CMS_IMAGE:-} CMS_DEPLOY_HOST=${CMS_DEPLOY_HOST:-} CMS_DEPLOY_HOST_IP=${CMS_DEPLOY_HOST_IP:-}" >> #{log}
    exit 0
    """)

    File.chmod!(path, 0o755)
    {path, log}
  end

  defp healthy, do: fn _host, _opts -> :ok end
  defp unhealthy(reason), do: fn _host, _opts -> {:error, reason} end

  describe "the ordering" do
    # Criterion 8007: migrate lands before the swap. Asserted from the
    # recorded timestamps, because the ordering is an observable property
    # rather than something to infer from the code's shape.
    test "migrates before it swaps", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert %Result{migrated_at: %DateTime{}, swapped_at: %DateTime{}} = result
      assert DateTime.compare(result.migrated_at, result.swapped_at) in [:lt, :eq]
    end

    test "records the health check between the two", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert DateTime.compare(result.migrated_at, result.health_ok_at) in [:lt, :eq]
      assert DateTime.compare(result.health_ok_at, result.swapped_at) in [:lt, :eq]
      assert result.live_version == :new
    end
  end

  describe "a failed migration" do
    # Criterion 8008: the previous version keeps serving, and nothing swaps.
    test "never swaps and leaves the previous version live", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, migrate_exit: 1)

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert result.failed_phase == :migrate
      assert result.swapped_at == nil
      assert result.live_version == :previous
      refute Result.swapped?(result)
    end

    test "does not run the health check or the swap at all", %{env: env} = ctx do
      # The fake script would exit 0 for swap; reaching it would set
      # swapped_at. Its absence is the proof the sequence stopped.
      script = deploy_script(ctx.env.cwd, migrate_exit: 1)

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: fn _, _ -> flunk("health check ran after a failed migration") end
        )

      assert result.health_ok_at == nil
      assert result.swapped_at == nil
    end
  end

  describe "a failed health check" do
    # Criterion 8009: no swap, and the reason names health so the report is
    # actionable rather than "deploy failed".
    test "never swaps, and says why in terms of health", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: unhealthy("responded 502")
        )

      assert result.failed_phase == :health
      assert result.swapped_at == nil
      assert result.live_version == :previous
      assert result.reason =~ ~r/health/i
      # The provider's own detail survives, so the cause is visible.
      assert result.reason =~ "502"
    end

    # A first deploy has no previous version, so the pre-swap check has
    # nothing to look at: the health phase probes whatever is currently
    # serving, and with nothing deployed the host refuses the connection. The
    # deploy that would create the site was being refused for the site not
    # existing yet — which is a deadlock, not a safety check.
    test "is not run at all when nothing has ever been deployed", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, first_deploy: true)

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: fn _host, _opts ->
            flunk("probed a host that has never had anything deployed to it")
          end
        )

      assert %DateTime{} = result.swapped_at, "the first deploy never reached the swap"
      assert result.live_version == :new
      assert result.failed_phase == nil
    end

    # Confirmed live against broken_oaths: kamal writes env/roles/<role>.env
    # as a side effect of a container *attempting* to boot, not of one
    # succeeding, and never removes it when that boot then crashes. A
    # crashed first attempt leaves migrate's own "first_deploy=1" signal
    # silent on every later run (the file already exists, so bin/deploy
    # never reprints it) even though nothing has ever actually gone live —
    # a deadlock, since the health check this then runs can never pass.
    # `environment_previously_deployed: false` is the platform's own,
    # independent answer, and it has to be enough on its own to skip health
    # even when the script-output signal disagrees.
    test "is also skipped when the platform's own record says nothing has ever gone live, even if the script's own signal disagrees",
         %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, first_deploy: false)

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          environment_previously_deployed: false,
          probe: fn _host, _opts ->
            flunk("probed a host the platform has never recorded a deploy for")
          end
        )

      assert %DateTime{} = result.swapped_at
      assert result.failed_phase == nil
    end

    # And the reprieve is only for that case: an existing deployment still
    # refuses to swap onto an unhealthy site.
    test "still guards a deployment that already exists", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, first_deploy: false)

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: unhealthy("responded 502")
        )

      assert result.failed_phase == :health
      assert result.swapped_at == nil
    end

    test "the migration still happened — it is the swap that is withheld", %{env: env} = ctx do
      script = deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: unhealthy("timeout")
        )

      assert %DateTime{} = result.migrated_at
      assert result.swapped_at == nil
    end
  end

  # `migrate` fails this exact way on a host that has never had a successful
  # deploy: kamal writes env/roles/<role>.env only as a side effect of
  # booting a container, so a virgin host has no such file, and `kamal app
  # exec` refuses before the migration itself ever runs. Confirmed live
  # against MarketMySpec's uat. The counter file is what lets a real
  # subprocess (a new OS process per invocation, sharing no Elixir state)
  # behave differently the second time `migrate` runs.
  defp bootstrap_deploy_script(dir, opts) do
    retry_migrate_exit = Keyword.get(opts, :retry_migrate_exit, 0)
    swap_exit = Keyword.get(opts, :swap_exit, 0)
    path = Path.join(dir, "fake_deploy")
    counter = Path.join(dir, "migrate_calls")

    File.write!(path, """
    #!/bin/sh
    case "$1" in
      migrate)
        COUNT=0
        [ -f #{counter} ] && COUNT=$(cat #{counter})
        COUNT=$((COUNT + 1))
        echo $COUNT > #{counter}
        if [ "$COUNT" -eq 1 ]; then
          echo "docker: open .kamal/apps/app/env/roles/web.env: no such file or directory"
          exit 125
        fi
        echo "migrate $2"
        exit #{retry_migrate_exit}
        ;;
      swap)
        echo "swap $2"
        exit #{swap_exit}
        ;;
    esac
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  describe "a first deploy that has never booted at all" do
    # The env file is what migrate is missing, and only a boot writes one —
    # so bootstrapping means swap runs once, early, purely to create it.
    test "bootstraps with a swap, then migrates, health-checks, and swaps again",
         %{env: env} = ctx do
      script = bootstrap_deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert %DateTime{} = result.bootstrapped_at
      assert %DateTime{} = result.migrated_at
      assert %DateTime{} = result.swapped_at
      assert result.live_version == :new
      assert result.failed_phase == nil
    end

    # Nothing was serving before the bootstrap, so there is nothing for the
    # health check to have protected — the same reprieve an ordinary first
    # deploy already gets (see "is not run at all when nothing has ever been
    # deployed" above), reached by a different route this time.
    test "skips the health check, same as any other first deploy", %{env: env} = ctx do
      script = bootstrap_deploy_script(ctx.env.cwd, [])

      result =
        Deploy.run(env, "prod",
          deploy_script: script,
          host: "app.example.com",
          probe: fn _host, _opts -> flunk("probed a host with nothing serving on it yet") end
        )

      assert %DateTime{} = result.swapped_at
    end

    # The bootstrap itself is what moved traffic — there is no previous
    # version for the ordinary migrate-failure wording to be talking about,
    # so this gets its own phase and its own honest reason.
    test "reports a failed bootstrap as its own phase, not an ordinary migrate failure",
         %{env: env} = ctx do
      script = bootstrap_deploy_script(ctx.env.cwd, swap_exit: 1)

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert result.failed_phase == :bootstrap
      assert result.swapped_at == nil
      assert result.reason =~ "never served anything"
    end

    # A double failure: the bootstrap succeeds (traffic already moved), but
    # the migration retried against it genuinely fails too. "the previous
    # version is still serving" would be a lie here — nothing was previous.
    test "names what actually happened when the retried migration also fails",
         %{env: env} = ctx do
      script = bootstrap_deploy_script(ctx.env.cwd, retry_migrate_exit: 1)

      result =
        Deploy.run(env, "prod", deploy_script: script, host: "app.example.com", probe: healthy())

      assert result.failed_phase == :migrate
      assert result.live_version == :new
      assert result.swapped_at == nil
      assert result.reason =~ "no previous version to fall back to"
    end
  end

  describe "Result" do
    # There is deliberately no :done field. swapped_at is the only evidence a
    # deploy completed, so a caller cannot report success for a refused run by
    # reading the wrong field.
    test "swapped?/1 is the single source of truth for completion" do
      refute Result.swapped?(%Result{})

      refute Result.swapped?(%Result{
               migrated_at: DateTime.utc_now(),
               health_ok_at: DateTime.utc_now()
             })

      assert Result.swapped?(%Result{swapped_at: DateTime.utc_now()})
    end

    test "has no field that claims success independently of the swap" do
      fields = %Result{} |> Map.from_struct() |> Map.keys()

      refute :done in fields
      refute :success in fields
      refute :status in fields
    end
  end

  describe "verify_hosts/2" do
    test "names which host failed and how" do
      probe = fn
        "good.example.com", _ -> :ok
        "bad.example.com", _ -> {:error, "responded 502"}
      end

      assert {:error, {:unhealthy, [{"bad.example.com", "responded 502"}]}} =
               Deploy.verify_hosts(["good.example.com", "bad.example.com"], probe: probe)
    end

    test "passes when every host answers" do
      assert {:ok, ["a.example.com", "b.example.com"]} =
               Deploy.verify_hosts(["a.example.com", "b.example.com"], probe: healthy())
    end
  end

  describe "probe/2" do
    test "a missing hostname is an error, not a crash" do
      assert {:error, reason} = Deploy.probe(nil, [])
      assert reason =~ "hostname"
    end

    # The gap that let four drills print `%Req.TransportError{reason: :timeout}`
    # onto the setup page: the tls step's formatter was only ever exercised
    # through an injected probe returning a raw struct, while the real probe
    # inspected the struct into a binary first — and binaries pass through the
    # formatter untouched. So this asserts on the production function.
    #
    # The transport failure is stubbed rather than provoked. These used an
    # RFC 2606 `.invalid` host so resolution could not succeed, which is sound
    # reasoning but still a real DNS lookup and a real timeout budget from the
    # unit suite. `Req.Test.transport_error/2` produces the same thing offline
    # and instantly, and says which failure is being asserted.
    test "a transport failure comes back as words, not a struct" do
      Req.Test.stub(Deploy, &Req.Test.transport_error(&1, :nxdomain))

      assert {:error, reason} = Deploy.probe("nothing.invalid", timeout_ms: 2_000)

      refute reason =~ "TransportError",
             "the struct reached the caller, which interpolates it into a sentence"

      refute reason =~ "reason:"
      assert is_binary(reason)
    end

    test "the scheme is selectable so a caller can tell 443 from 80" do
      # Records the URL the option produced, which is what this is actually
      # about — the old version asserted only that an unresolvable host failed,
      # which it would have done under either scheme.
      test_pid = self()

      Req.Test.stub(Deploy, fn conn ->
        send(test_pid, {:probed, conn.scheme, conn.port})
        Req.Test.transport_error(conn, :nxdomain)
      end)

      assert {:error, _} = Deploy.probe("nothing.invalid", scheme: :http, timeout_ms: 2_000)

      assert_receive {:probed, :http, 80}
    end
  end

  # The generated `bin/deploy` waits for GitHub Actions and pulls from ghcr.io
  # with `gh auth token`. Setup has already built the image on its own builder
  # and pushed it to the project's own registry, so it has to be able to say
  # so — criterion 8240 is a deploy that needs no GitHub credential.
  describe "what setup tells the deploy script" do
    test "the image it built reaches both phases", ctx do
      {script, log} = recording_script(ctx.env.cwd)

      Deploy.run(ctx.env, "uat",
        deploy_script: script,
        host: "uat.example.com",
        host_ip: "1.2.3.4",
        image: "localhost:5000/app:abc123",
        probe: healthy()
      )

      recorded = File.read!(log)

      assert recorded =~ "migrate CMS_IMAGE=localhost:5000/app:abc123"

      assert recorded =~ "swap CMS_IMAGE=localhost:5000/app:abc123",
             "the swap deploys the same image the migration ran against, or it " <>
               "is not the thing that was proven"
    end

    # The IP belongs to a server an earlier step created, and a different one
    # on every provision, so no committed config can carry it — which is why
    # the generated config has `<UAT_HOST_IP>` rather than an address.
    test "the host and its address are supplied at run time", ctx do
      {script, log} = recording_script(ctx.env.cwd)

      Deploy.run(ctx.env, "uat",
        deploy_script: script,
        host: "uat.example.com",
        host_ip: "1.2.3.4",
        image: "localhost:5000/app:abc123",
        probe: healthy()
      )

      recorded = File.read!(log)

      assert recorded =~ "CMS_DEPLOY_HOST=uat.example.com"
      assert recorded =~ "CMS_DEPLOY_HOST_IP=1.2.3.4"
    end

    # An empty variable is worse than an absent one: the script cannot tell
    # "not configured" from "configured to nothing", and would deploy an image
    # named "".
    test "nothing is passed for a value setup does not have", ctx do
      {script, log} = recording_script(ctx.env.cwd)

      Deploy.run(ctx.env, "uat",
        deploy_script: script,
        host: "uat.example.com",
        probe: healthy()
      )

      recorded = File.read!(log)

      assert recorded =~ "CMS_IMAGE="
      refute recorded =~ "CMS_IMAGE=localhost"
      assert recorded =~ "CMS_DEPLOY_HOST_IP="
    end
  end

  # `opts[:run]` is the same escape hatch `Backups.run_script/4` already has:
  # kamal is meant to connect *to* the app server over SSH, never to run on
  # whichever machine called this — a harness's environment cannot shell out
  # at all, and even a real local checkout is the wrong place. `Builder`
  # supplies this bound to the box the image was just built and pushed on.
  describe "running via opts[:run] instead of shelling out locally" do
    test "migrate and swap run through it, not Environments.cmd/4", %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      result =
        Deploy.run(env, "prod",
          deploy_script: "bin/deploy",
          host: "app.example.com",
          image: "localhost:5000/app:abc123",
          run: run,
          remote_dir: "/build",
          probe: healthy()
        )

      assert_receive {:ran, migrate_command}
      assert_receive {:ran, swap_command}

      assert migrate_command =~ "cd '/build' &&"
      assert migrate_command =~ "bin/deploy 'migrate' 'prod'"
      assert migrate_command =~ "CMS_IMAGE='localhost:5000/app:abc123'"

      assert swap_command =~ "bin/deploy 'swap' 'prod'"
      assert Result.swapped?(result)
    end

    # `opts[:run]`'s box is *not* actually bare here — it boots from a
    # prebuilt image, and whatever known_hosts held when that image was
    # captured comes back on every builder booted from it since. An append
    # alone would leave that stale entry sitting alongside a fresh, correct
    # one, and Net::SSH treats two disagreeing records for the same host as
    # a mismatch — the same failure host-key verification exists to catch,
    # self-inflicted by a builder image nobody ever expected to carry state.
    # Confirmed live against broken_oaths: identical HostKeyMismatch, same
    # fingerprint, recurring even with a targeted `ssh-keygen -R` removal,
    # and then again even with a full wipe + retry loop on the *user*
    # known_hosts alone — the box is destroyed after this one build either
    # way, so a full wipe is what actually earns trust here, not whatever
    # survived from the image it booted from. Also wipes the *global*
    # known_hosts files: Net::SSH's `KnownHosts.hostfiles` merges keys from
    # `/etc/ssh/ssh_known_hosts[2]` right alongside the user files, and
    # Kamal never narrows that — a stale, root-owned entry there survived
    # every earlier user-file-only fix and is what actually explained the
    # mismatch recurring with the identical fingerprint every time rather
    # than flapping.
    test "seeds the target's host key before kamal ever tries to reach it", %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~
               "rm -f ~/.ssh/known_hosts ~/.ssh/known_hosts2 /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2",
             "expected both the builder's user AND global known_hosts wiped before it is trusted again"

      assert migrate_command =~ "ssh-keyscan -T 10 -H 'app.example.com' >> ~/.ssh/known_hosts"

      assert migrate_command =~ "[ -s ~/.ssh/known_hosts ] && break",
             "expected a retry loop rather than trusting one scan attempt"

      assert Regex.match?(
               ~r/rm -f ~\/\.ssh\/known_hosts.*ssh_known_hosts2; for i in 1 2 3; do ssh-keyscan.*; cd '\/build'/,
               migrate_command
             ),
             "expected known_hosts wiped, then the host key seeded, before the script runs"
    end

    # `ensure_kamal/1`'s ed25519/bcrypt_pbkdf install was only ever meant to
    # let the delivered *client* key authenticate — it has an unasked-for
    # side effect of also letting Net::SSH negotiate ed25519 as the *host
    # key* algorithm. Confirmed live against broken_oaths: once it did, host
    # key verification failed against a known_hosts entry independently
    # proven correct (identical fingerprint, all three types present) —
    # every attempt before that gem existed on the box negotiated rsa/ecdsa
    # and never once mismatched. Restricting back to that known-good set
    # sidesteps whatever the comparison bug actually is, without touching
    # the delivered client key (still ed25519) or any shared secret.
    test "restricts the host key algorithms Net::SSH will accept back to the known-good set",
         %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "rm -f ~/.ssh/config"
      assert migrate_command =~ "Host app.example.com"
      assert migrate_command =~ "HostKeyAlgorithms ssh-rsa,rsa-sha2-512,rsa-sha2-256"

      refute migrate_command =~ "ssh-ed25519",
             "the allow-list must not include the algorithm being sidestepped"

      assert Regex.match?(
               ~r/done; rm -f ~\/\.ssh\/config; printf .*>> ~\/\.ssh\/config; .*cd '\/build'/,
               migrate_command
             ),
             "expected the algorithm restriction written after known_hosts, before the script runs"
    end

    test "does not try to seed a host it was never given", %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}
      refute migrate_command =~ "ssh-keyscan"
      refute migrate_command =~ "printf"
      refute migrate_command =~ "net_ssh_probe"
    end

    # Two independently-confirmed-correct keys (ed25519, then rsa — each an
    # exact fingerprint match to an outside scan) still raised
    # `HostKeyMismatch` live against broken_oaths, ruling out an
    # algorithm-specific cause. This calls `Net::SSH::KnownHosts.search_for/1`
    # directly — the same method `Transport::Session#host_keys` calls
    # internally — against the same "host,ip" string Net::SSH itself builds
    # (`host_as_string`), so the next failure shows whether net-ssh's own
    # lookup finds the key kamal cannot, rather than guessing at another
    # kamal-specific explanation.
    test "probes Net::SSH's own known_hosts lookup directly, ahead of kamal's real connection",
         %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "ruby -e"
      assert migrate_command =~ "net/ssh"
      assert migrate_command =~ "host=\"app.example.com\""
      assert migrate_command =~ "Net::SSH::KnownHosts.search_for(target)"
      assert migrate_command =~ "net_ssh_probe"
      assert migrate_command =~ "Net::SSH::Version::STRING"

      assert Regex.match?(~r/HostKeyAlgorithms.*ruby -e.*cd '\/build'/, migrate_command),
             "expected the probe to run after the config is written, before the script runs"
    end

    # `~/.ssh/config` is ours to wipe and control; `/etc/ssh/ssh_config`
    # ships with the image and net-ssh reads it by default regardless
    # (`Config.default_files` includes it). Confirmed by diffing net-ssh
    # 7.3.2 against 7.3.3: the older version's `UserKnownHostsFile` handling
    # never split a space-separated multi-path value, which on Debian/
    # Ubuntu's own stock `UserKnownHostsFile ~/.ssh/known_hosts
    # ~/.ssh/known_hosts2` line turns into one garbled, nonexistent path —
    # silently emptying `host_keys` regardless of what we write to the real
    # file. Whether that applies live depends on which net-ssh actually
    # loads, which is exactly what the version line in each probe answers.
    test "checks the system ssh_config this codebase never writes, unconditionally", %{
      env: env
    } do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "UserKnownHostsFile|HostKeyAlgorithms"
      assert migrate_command =~ "/etc/ssh/ssh_config"
      assert String.starts_with?(migrate_command, "grep -iE")
    end

    # The first probe (above) found and correctly fingerprinted the exact
    # key kamal's own connection then rejected moments later — but that
    # probe runs before `cd`, and kamal runs after. A project with its own
    # Gemfile can carry its own net-ssh, and a bundler-aware `kamal` binstub
    # checked into the repo would shadow the global one the moment the
    # working directory changes. Repeats the identical probe from inside
    # the tree, plus `which kamal` and whatever Gemfile.lock says about
    # net-ssh, so a difference between the two probes' output points at the
    # version instead of guessing at Net::SSH internals again.
    test "repeats the probe from inside the project directory, where kamal actually runs",
         %{env: env} do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "which kamal"
      assert migrate_command =~ "gem list net-ssh"
      assert migrate_command =~ "Gemfile.lock"
      assert migrate_command =~ "net_ssh_probe_incd"

      assert Regex.match?(
               ~r/cd '\/build' && which kamal.*net_ssh_probe_incd.*bin\/deploy/,
               migrate_command
             ),
             "expected the in-directory probe to run after cd, before the script"
    end

    # Every prior probe replicated only the known_hosts *lookup* — never a
    # real handshake negotiating a real host-key algorithm against a real
    # presented key, verified by whatever `Net::SSH::Verifiers` class
    # kamal's SSHKit backend actually selects. Two lookup-only probes
    # agreed with each other and both found the exact key kamal then
    # rejected, which proves the lookup works, not that the comparison
    # consuming its result does. This attempts a real `Net::SSH.start`
    # against the same host with the same delivered key, bypassing kamal
    # and SSHKit entirely — reproducing `HostKeyMismatch` here would
    # confirm the bug is inside net-ssh's own verification path.
    test "attempts a real Net::SSH connection, bypassing kamal and SSHKit entirely",
         %{env: env} do
      test_pid = self()
      {:ok, key_dir} = Briefly.create(directory: true)
      key_path = Path.join(key_dir, "id_ed25519")
      File.write!(key_path, "fake key bytes")

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        ssh_key_path: key_path,
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "Net::SSH.start(\"app.example.com\""
      assert migrate_command =~ "keys_only: true"
      assert migrate_command =~ "Net::SSH::HostKeyMismatch"
      assert migrate_command =~ "net_ssh_real_probe"

      assert Regex.match?(~r/net_ssh_probe.*net_ssh_real_probe.*cd '\/build'/, migrate_command),
             "expected the real-connection probe after the lookup-only probe, before the script"
    end

    # `CMS_SSH_KEY_PATH` travels as an env var — only ever a path. Kamal
    # reads it on the builder to make its own, second outbound ssh
    # connection to the app host, which needs the key's actual bytes to be
    # there, not just its name. Confirmed live: without this, kamal fell
    # through to interactive password auth and died `Errno::ENOTTY`.
    test "delivers the ssh key's own bytes onto the box, not just its path", %{env: env} do
      test_pid = self()
      {:ok, key_dir} = Briefly.create(directory: true)
      key_path = Path.join(key_dir, "id_ed25519")

      File.write!(
        key_path,
        "-----BEGIN OPENSSH PRIVATE KEY-----\nfake+key/data==\n-----END OPENSSH PRIVATE KEY-----\n"
      )

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        ssh_key_path: key_path,
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "mkdir -p #{shell_quote(Path.dirname(key_path))}"
      assert migrate_command =~ "base64 -d > #{shell_quote(key_path)}"
      assert migrate_command =~ "chmod 600 #{shell_quote(key_path)}"

      [_mkdir, encoded_and_rest] = String.split(migrate_command, "echo ", parts: 2)
      [encoded, _rest] = String.split(encoded_and_rest, " | base64 -d", parts: 2)

      assert encoded
             |> String.trim("'")
             |> Base.decode64!() == File.read!(key_path)

      assert Regex.match?(~r/base64 -d > .* && chmod 600 .*; cd/, migrate_command),
             "the key must be written before bin/deploy ever runs"
    end

    # Temporary: everything about key delivery tested clean in isolation
    # (this exact base64 round-trip reproduces a byte-identical, working
    # key file; the account key authenticates directly with
    # `IdentitiesOnly`; kamal's own `kamal config` correctly resolves
    # `keys`/`keys_only` from this same env var) — yet the live deploy
    # still falls back to password on the builder itself, which none of
    # that isolated testing can observe. This confirms the diagnostic
    # actually lands in the command kamal receives, not what it reports.
    test "reports the delivered key's own permissions on the builder, before the script runs",
         %{env: env} do
      test_pid = self()
      {:ok, key_dir} = Briefly.create(directory: true)
      key_path = Path.join(key_dir, "id_ed25519")
      File.write!(key_path, "fake key bytes")

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        ssh_key_path: key_path,
        probe: healthy()
      )

      assert_receive {:ran, migrate_command}

      assert migrate_command =~ "ls -la #{shell_quote(key_path)}"
      assert migrate_command =~ "whoami"
      assert migrate_command =~ "awk '{print $2}' ~/.ssh/known_hosts"

      assert Regex.match?(~r/chmod 600 .*&& ls -la .*; whoami; awk .*; cd/, migrate_command),
             "expected the permissions check after delivery, before the script runs"
    end

    defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

    # `resolve_script/2` joins the caller's own `env.cwd` onto a relative
    # script name — right when the script has to be found on this machine,
    # wrong when `opts[:run]` means it lives on a box neither `env` nor this
    # process can see the path of. The relative name has to travel as-is; the
    # `cd` into `opts[:remote_dir]` is what resolves it, on the far end.
    test "the caller's own cwd never gets joined onto the script name", ctx do
      test_pid = self()

      run = fn [command] ->
        send(test_pid, {:ran, command})
        {"", 0}
      end

      Deploy.run(ctx.env, "prod",
        deploy_script: "bin/deploy",
        host: "app.example.com",
        run: run,
        remote_dir: "/build",
        probe: healthy()
      )

      assert_receive {:ran, command}

      refute command =~ ctx.env.cwd,
             "the local tmp dir leaked into a command meant for a different box"
    end

    test "a failed migration still refuses the swap", %{env: env} do
      run = fn [command] ->
        if String.contains?(command, "migrate") do
          {"boom", 1}
        else
          flunk("swap ran after a failed migration")
        end
      end

      result =
        Deploy.run(env, "prod",
          deploy_script: "bin/deploy",
          host: "app.example.com",
          run: run,
          remote_dir: "/build"
        )

      assert result.failed_phase == :migrate
      refute Result.swapped?(result)
    end
  end
end

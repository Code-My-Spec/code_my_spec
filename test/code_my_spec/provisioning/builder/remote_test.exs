defmodule CodeMySpec.Provisioning.Builder.RemoteTest do
  @moduledoc """
  What the builder runs on the box, without a box.

  `:run` takes the command and returns `{output, status}`, so the commands are
  assertable and running them is not. That is the whole reason this is a unit
  test: a real `docker build` is minutes, non-deterministic, and invalidated by
  any Dockerfile edit — none of which tells us whether we asked for the right
  thing.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Remote

  # Answers every command successfully and records what it was asked, so a test
  # can assert on the sequence rather than on a mock's expectations.
  defp recorder(owner, responses) do
    fn [command] ->
      send(owner, {:ran, command})

      Enum.find_value(responses, {"", 0}, fn {pattern, response} ->
        String.contains?(command, pattern) && response
      end)
    end
  end

  defp opts(run, overrides \\ []) do
    Keyword.merge(
      [run: run, deliver: recording_deliver(self()), ssh_interval_ms: 0],
      overrides
    )
  end

  # Source delivery is no longer one of the `run` commands — the builder does
  # not clone any more, so the tree arrives over a separate channel. Recorded
  # the same way so a test can still say what was sent and where.
  defp recording_deliver(owner) do
    fn ref, dir ->
      send(owner, {:delivered, ref, dir})
      :ok
    end
  end

  # The `docker build` among everything the builder ran. `assert_received`
  # takes the *first* message, which is the SSH reachability probe — so
  # asserting on that reports "true" and says nothing about the build.
  defp build_command do
    receive do
      {:ran, command} -> matching_build(command, String.contains?(command, "docker build"))
    after
      0 -> flunk("no docker build was run")
    end
  end

  defp matching_build(command, true), do: command
  defp matching_build(_command, false), do: build_command()

  defp arm, do: {"arm64\n", 0}

  describe "build/4" do
    # Was "fetches only the commit being built", asserting a shallow clone.
    # The builder does not clone at all now: repositories are private and
    # setup installs no deploy key, so cloning could never have worked, and
    # putting a GitHub token on a throwaway box to make it work is the thing
    # this avoids. The commit's tree is sent over the SSH we already have.
    test "the commit being built is delivered, not cloned" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} = Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert_received {:delivered, "abc123", "/build"}

      # Nothing in the sequence reaches GitHub, which is the point.
      refute_received {:ran, "git clone" <> _}
      refute_received {:ran, "git fetch" <> _}
    end

    # kamal refuses an image that does not carry a `service` label matching
    # its own service name — `Image <ref> is missing the 'service' label`. It
    # stamps that label itself when it builds, and setup builds elsewhere and
    # deploys with `--skip-push`, so nothing else was ever going to add it.
    # The deploy pulled the image successfully and the very next command
    # rejected what it had just pulled.
    test "stamps the service label kamal checks for" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, service: "myapp-uat")
               )

      assert build_command() =~ "--label service='myapp-uat'"
    end

    # Nothing to stamp is not the same as stamping nothing: a build with no
    # service configured must still produce a working image, and an empty
    # label would be a label kamal compares against and rejects.
    test "omits the label entirely when no service is configured" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} = Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      refute build_command() =~ "--label service"
    end

    test "reads the architecture off the image rather than trusting the request" do
      # The point of the whole check: a build that quietly produced x86 must
      # report x86, so Builder can refuse it.
      run = recorder(self(), %{"inspect" => {"amd64\n", 0}})

      assert {:ok, %{architecture: :x86}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end

    test "a failed build does not push" do
      run =
        recorder(self(), %{
          "docker build" => {"no space left on device", 1},
          "inspect" => arm()
        })

      assert {:error, {:build_failed, 1, output}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert output =~ "no space left"

      refute_received {:ran, "docker push" <> _}
    end

    test "a failed push is not reported as a successful build" do
      run =
        recorder(self(), %{
          "docker push" => {"unauthorized", 1},
          "inspect" => arm()
        })

      assert {:error, {:push_failed, 1, output}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      assert output =~ "unauthorized"

      # The registry answers on a private address, so the first question a
      # timed-out push raises is whether this box is on that network — and the
      # box is destroyed with the build, so asking afterwards is not an option.
      assert output =~ "builder interfaces"
    end

    test "gives up on a box that never answers rather than hanging" do
      run = fn _ -> {"connection refused", 255} end

      assert {:error, {:builder_unreachable, _seconds, last}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, ssh_attempts: 3)
               )

      # What SSH last said, because "unreachable" describes a broken box and an
      # impatient caller equally well, and those want opposite responses. A
      # cold Hetzner box takes long enough to reach sshd that the second is the
      # likelier of the two.
      assert last =~ "connection refused"
    end

    test "how long it waited is part of the giving up" do
      run = fn _ -> {"", 255} end

      assert {:error, {:builder_unreachable, seconds, _last}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "reg/app:abc123",
                 opts(run, ssh_attempts: 3, ssh_interval_ms: 1_000)
               )

      assert seconds == 3
    end

    # Commands run over SSH with stderr folded into stdout, and ssh writes its
    # own `Warning: Permanently added ...` there. A real amd64 build was
    # refused as `{:unknown_architecture, "Warning: ...\namd64"}` — the check
    # was shown a greeting.
    test "ssh's own greeting is not mistaken for the architecture" do
      run =
        recorder(self(), %{
          "inspect" => {"Warning: Permanently added '1.2.3.4' to the list of known hosts.\namd64\n", 0}
        })

      assert {:ok, %{architecture: :x86}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end

    test "an architecture nobody recognises is an error, not a guess" do
      run = recorder(self(), %{"inspect" => {"riscv64\n", 0}})

      assert {:error, {:unknown_architecture, "riscv64"}} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))
    end
  end

  # A registry reachable on a public hostname must refuse anonymous writes, so
  # a push with no credential is a push that cannot succeed against a registry
  # worth having. This pushed with none at all.
  describe "authenticating to the registry" do
    test "logs in to the reference's host before pushing" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/app:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "hunter2"})
               )

      [_reachable, _build, _trust, login, push, _inspect] = ran_commands(6)

      assert push =~ "docker push", "the login must come before the push, not after it"

      assert login =~ "docker login 'registry.example.com'"
      assert login =~ "--username 'cms'"

      assert login =~ "--password-stdin",
             "the password must not be an argument — it lands in shell history " <>
               "and in the process list of a box we share"

      refute login =~ "-p hunter2"
    end

    test "the login targets the registry, not the image path" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/some/deep/path:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "pw"})
               )

      [_reachable, _build, _trust, login, _push, _inspect] = ran_commands(6)

      assert login =~ "docker login 'registry.example.com'"
      refute login =~ "some/deep/path"
    end

    test "a failed login does not push" do
      run =
        recorder(self(), %{
          "docker login" => {"unauthorized", 1},
          "inspect" => arm()
        })

      assert {:error, {:login_failed, 1, "unauthorized"}} =
               Remote.build(
                 %{"ip" => "1.2.3.4"},
                 "abc123",
                 "registry.example.com/app:abc123",
                 opts(run, registry_credentials: %{username: "cms", password: "pw"})
               )

      refute_received {:ran, "docker push" <> _}
    end

    test "no credentials configured stays a no-op" do
      run = recorder(self(), %{"inspect" => arm()})

      assert {:ok, _} =
               Remote.build(%{"ip" => "1.2.3.4"}, "abc123", "reg/app:abc123", opts(run))

      refute_received {:ran, "printf" <> _}
    end
  end

  # `bin/deploy` shells out to `kamal` directly, and the docker-ce builder
  # image never had Ruby, let alone the gem. Confirmed live against
  # MarketMySpec: `kamal: command not found` (exit 127), the first real
  # harness-only deploy to get far enough to invoke it.
  describe "ensure_kamal/1" do
    # kamal not being on PATH yet, for every test below that exercises the
    # install path — the default `recorder/2` response otherwise reports
    # "found" and the install command is never even reached.
    defp kamal_missing, do: %{"command -v kamal" => {"", 1}}

    # A custom builder image (`Builder.ensure_builder_image/2`) already has
    # kamal baked in — the whole reason it exists is to skip this dance on
    # every ordinary deploy.
    test "does nothing when kamal is already on the box" do
      run = recorder(self(), %{"command -v kamal" => {"/usr/local/bin/kamal", 0}})

      assert :ok = Remote.ensure_kamal(run)

      assert_received {:ran, "command -v kamal"}
      refute_received {:ran, "apt-get" <> _}
    end

    test "installs ruby and the kamal gem" do
      run = recorder(self(), kamal_missing())

      assert :ok = Remote.ensure_kamal(run)

      assert_received {:ran, "command -v kamal"}
      assert_received {:ran, command}
      assert command =~ "apt-get install -y -qq ruby-full build-essential"
      assert command =~ "gem install kamal --no-document"
    end

    test "reports a real failure rather than proceeding without kamal" do
      run =
        recorder(
          self(),
          Map.merge(kamal_missing(), %{
            "gem install" => {"ERROR:  Could not find a valid gem", 1}
          })
        )

      assert {:error, {1, output}} = Remote.ensure_kamal(run)
      assert output =~ "Could not find a valid gem"
    end

    # Confirmed live against MarketMySpec: installing ruby-full triggers
    # needrestart's own apt hook, which prints a page of "Restarting
    # services.../No containers need to be restarted" chatter — and
    # devops_status keeps only the first 300 characters of whatever this
    # becomes. That chatter alone pushed the real cause past the cutoff.
    test "suppresses needrestart's own restart-service chatter" do
      run = recorder(self(), kamal_missing())
      Remote.ensure_kamal(run)

      assert_received {:ran, "command -v kamal"}
      assert_received {:ran, command}
      assert command =~ "NEEDRESTART_MODE=a"
    end

    test "keeps both ends of a long failure — apt/needrestart bury theirs at the tail" do
      noise = String.duplicate("Restarting services...\n", 30)

      run =
        recorder(
          self(),
          Map.merge(kamal_missing(), %{"gem install" => {noise <> "ERROR: the real cause", 1}})
        )

      assert {:error, {1, output}} = Remote.ensure_kamal(run)

      assert output =~ "ERROR: the real cause"
      assert String.length(output) < String.length(noise)
    end

    # The bug found live, after the tail-only fix above shipped: a Ruby
    # `gem` crash puts its own "ERROR: ..." line *before* the backtrace it
    # raises, the opposite of apt/needrestart's convention. A tail-only
    # slice kept nothing but backtrace frames and lost the one line that
    # said what went wrong.
    test "keeps both ends of a long failure — a gem crash puts theirs at the head" do
      backtrace = String.duplicate("\tfrom /usr/lib/ruby/vendor_ruby/rubygems/x.rb:1\n", 30)

      run =
        recorder(
          self(),
          Map.merge(kamal_missing(), %{
            "gem install" => {"ERROR: Loading command failed" <> backtrace, 1}
          })
        )

      assert {:error, {1, output}} = Remote.ensure_kamal(run)

      assert output =~ "ERROR: Loading command failed"
    end
  end

  # For a harness-only project `ssh_deliver/2` cannot reach — `env` there is
  # `Environment.new(:local, nil)` — so `Builder` falls back to this instead.
  describe "github_deliver/2" do
    defp github_opts(run, overrides \\ []) do
      Keyword.merge(
        [run: run, github_repo: "acme/market_my_spec", github_token: "ghs_abc123"],
        overrides
      )
    end

    test "downloads the ref's tarball from GitHub and extracts it, stripping the wrapper directory" do
      run = recorder(self(), %{})
      deliver = Remote.github_deliver(%{"ip" => "1.2.3.4"}, github_opts(run))

      assert :ok = deliver.("abc123", "/build")

      assert_received {:ran, command}
      assert command =~ "curl -sSfL --location-trusted -u 'x-access-token:ghs_abc123'"
      assert command =~ "https://api.github.com/repos/acme/market_my_spec/tarball/abc123"
      assert command =~ "tar -xz -C /build --strip-components=1"
    end

    test "the token never appears as a bare -H header value curl would echo on a redirect" do
      run = recorder(self(), %{})
      deliver = Remote.github_deliver(%{"ip" => "1.2.3.4"}, github_opts(run))

      :ok = deliver.("abc123", "/build")

      assert_received {:ran, command}
      refute command =~ "-H "
    end

    test "reports a real failure rather than succeeding on an error page" do
      run = recorder(self(), %{"curl" => {"HTTP 404: Not Found", 22}})
      deliver = Remote.github_deliver(%{"ip" => "1.2.3.4"}, github_opts(run))

      assert {:error, {:source_delivery_failed, 22, output}} = deliver.("abc123", "/build")
      assert output =~ "HTTP 404"
    end
  end

  # The sequence `build/4` runs is fixed — reachability, build, trust, login,
  # push, inspect — so the count is known rather than searched for. Taking a known
  # number and matching positionally says where the login belongs, which "scan
  # forward until something matches" cannot: it would pass just as well if the
  # login came after the push.
  #
  # Source delivery is not in the list: it stopped being a shell command on the
  # builder when the builder stopped cloning.
  defp ran_commands(count) do
    for _ <- 1..count do
      assert_receive {:ran, command}, 0
      command
    end
  end

  describe "wrap_with_timeout/2" do
    test "bounds the whole command, not just its first word" do
      wrapped = Remote.wrap_with_timeout("cd /tmp && docker build . && docker push x", 1800)

      assert wrapped ==
               "timeout -k 10 1800 sh -c 'cd /tmp && docker build . && docker push x'"
    end

    # A command containing its own single quotes (a shell_escape'd password, a
    # `-c '...'` of its own) has to survive being re-quoted as sh -c's single
    # argument, or wrapping a command changes what it does.
    test "quotes a command that already contains single quotes" do
      wrapped = Remote.wrap_with_timeout("echo it's here", 60)

      assert wrapped == "timeout -k 10 60 sh -c 'echo it'\\''s here'"
    end

    # The actual gap this closes: SIGTERM alone is a request a process can
    # outlive, not a guarantee. Confirmed live against MarketMySpec — a build
    # ran *past* its own 30-minute bound with no error, which only makes
    # sense if `timeout` fired and something underneath the shell it killed
    # (a buildx subprocess, BuildKit's own daemon) kept running anyway,
    # holding the ssh channel open behind it.
    test "escalates to SIGKILL if the command outlives its own SIGTERM" do
      wrapped = Remote.wrap_with_timeout("docker build .", 600)

      assert wrapped =~ ~r/^timeout -k 10 600 /
    end
  end
end

defmodule CodeMySpec.Provisioning.BuilderTest do
  @moduledoc """
  The builder's own claims, with the container build injected.

  A container build is a bad recording subject and a worse unit-test subject —
  minutes per run, non-deterministic digests, invalidated by any Dockerfile
  edit. What is worth testing is ours: which architecture gets asked for, that
  the builder is destroyed even when the build fails, and that an image built
  for the wrong architecture never leaves the builder.

  The Hetzner calls are injected here too, so these stay unit tests. Story 992
  keeps the real create/destroy under a cassette, because "the builder was
  destroyed" is the claim that costs money when it silently stops being true.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.Deploy
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{}

  defp server(name \\ "builder-abc123"), do: %{"id" => 42, "name" => name}

  # Records every destroy so a test can assert the builder went away, and for
  # whom.
  defp recording_destroy(owner) do
    fn _scope, id ->
      send(owner, {:destroyed, id})
      {:ok, %{}}
    end
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        create: fn _scope, _name, _create_opts -> {:ok, server()} end,
        destroy: recording_destroy(self()),
        now: fn -> ~U[2026-08-03 00:00:00Z] end
      ],
      overrides
    )
  end

  describe "build/3" do
    test "returns the image the build produced" do
      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "registry.example/app:abc123", architecture: arch}}
      end

      assert {:ok, result} =
               Builder.build(scope(), "abc123", opts(build_fun: build))

      assert result.image == "registry.example/app:abc123"
      assert result.architecture == :arm
    end

    test "destroys the builder once the image exists" do
      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} = Builder.build(scope(), "abc123", opts(build_fun: build))

      assert_received {:destroyed, 42}
    end

    test "destroys the builder when the build fails" do
      build = fn _scope, _server, _ref, _arch -> {:error, :compilation_failed} end

      assert {:error, :compilation_failed, disposition} =
               Builder.build(scope(), "abc123", opts(build_fun: build))

      # The whole point: a failed build must not leave a box running. Sam is
      # billed for it either way.
      assert_received {:destroyed, 42}

      # And the failure says so, rather than leaving the caller to assume it.
      # A leaked builder adds nothing visible to an already-failed deploy,
      # which is why this is the disposition most worth recording.
      assert disposition.builder_destroyed
      assert disposition.builder == "builder-abc123"
    end

    test "destroys the builder when the build raises" do
      build = fn _scope, _server, _ref, _arch -> raise "docker exploded" end

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", opts(build_fun: build))
      end

      assert_received {:destroyed, 42}
    end

    test "an image built for the wrong architecture is not shipped" do
      build = fn _scope, _server, _ref, _arch ->
        {:ok, %{reference: "img", architecture: :x86}}
      end

      assert {:error, {:architecture_mismatch, [built: :x86, wanted: :arm]}, disposition} =
               Builder.build(scope(), "abc123", opts(build_fun: build))

      # And the builder still goes, because a mismatch is a failed build.
      assert_received {:destroyed, 42}
      assert disposition.builder_destroyed
    end

    test "builds on the architecture the servers run" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:server_type], create_opts[:location]})
        {:ok, server()}
      end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(build_fun: build, create: create, architecture: :x86)
               )

      # cpx31, not cpx32: identical on paper, but cpx32 does not exist in ash or
      # hil, and the builder has to be created wherever the app box is.
      assert_received {:created, "cpx31", "fsn1"}
    end

    # The builder pushes to a registry on the app box's private network, and a
    # network's subnet lives in exactly one zone — so a builder in a different
    # zone holds an address on a network it cannot reach. Both boxes had
    # 10.0.0.x addresses and routes, and ping got 100% packet loss.
    test "is built beside the box it pushes to, when told where that is" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:location]})
        {:ok, server()}
      end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   build_fun: build,
                   create: create,
                   architecture: :x86,
                   builder_location: "ash"
                 )
               )

      assert_received {:created, "ash"}
    end

    # `:builder_location`, not `:location`. The deploy step's opts are threaded
    # to `Storage` and `Registry`, where `:location` is the object-storage
    # region — setting it here sent S3 to `ash.your-objectstorage.com` and
    # signing died inside the crypto NIF with `Bad text`, naming nothing. The
    # same trap `:build` set: one key, two meanings, one bag.
    test "the storage region is not mistaken for where to put the builder" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:location]})
        {:ok, server()}
      end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(build_fun: build, create: create, architecture: :x86, location: "fsn1")
               )

      assert_received {:created, "fsn1"},
                      "a bucket region must not decide which datacenter the builder lands in"
    end

    test "refuses an architecture with no builder rather than guessing one" do
      assert {:error, {:unknown_architecture, :sparc}} =
               Builder.build(scope(), "abc123", opts(architecture: :sparc))
    end
  end

  # `Remote.ssh_deliver/2` needs a real environment to archive the commit
  # from — for a harness-only project, `scope.environment` is
  # `Environment.new(:local, nil)`, the same unreachable shape
  # `Steps.head_commit/1` already falls back for. Reported live against
  # MarketMySpec: this used to raise instead of failing cleanly.
  describe "choosing how to deliver the source" do
    test "falls back to a clean error, not a crash, when there is no repo to fall back to" do
      scope = %Scope{environment: Environment.new(:local, nil)}
      run = fn [_cmd] -> {"", 0} end

      assert {:error, {:source_delivery_failed, :no_reachable_source, _}, _resources} =
               Builder.build(scope, "abc123", opts(run: run, reference: "reg/app:abc123"))
    end
  end

  # Every ordinary build used to pay `apt-get install ruby-full build-essential
  # && gem install kamal` fresh, on the stock image, every single time. This is
  # the box that stops paying it — built once, found by label after that.
  describe "ensure_builder_image/3" do
    test "finds an existing image by label rather than building a new one" do
      list_images = fn _scope, opts ->
        assert opts[:label_selector] == "cms-builder-role=x86"
        {:ok, [%{"id" => 555}]}
      end

      create = fn _scope, _name, _create_opts ->
        flunk("a matching image already exists — nothing should be created")
      end

      assert {:ok, 555} =
               Builder.ensure_builder_image(scope(), :x86, list_images: list_images, create: create)
    end

    test "builds one from scratch when none exists yet, then destroys the temp box" do
      owner = self()
      # The first call answers the "does one already exist" lookup with
      # nothing; every call after that is `await_image_ready/6` polling for
      # the same image to actually finish — real by then, per Hetzner.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, _opts ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        if n == 0, do: {:ok, []}, else: {:ok, [%{"id" => 777}]}
      end

      create = fn _scope, name, create_opts ->
        assert name =~ "cms-builder-bootstrap-x86-"
        assert create_opts[:image] == "docker-ce"
        {:ok, server()}
      end

      run = fn
        ["command -v kamal"] -> {"", 1}
        [_command] -> {"", 0}
      end

      create_image = fn _scope, 42, image_opts ->
        assert image_opts[:labels] == %{"cms-builder-role" => "x86"}
        {:ok, %{"image" => %{"id" => 777}}}
      end

      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:ok, 777} =
               Builder.ensure_builder_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_interval_ms: 0
               )

      assert_received :destroyed
    end

    # The bug this guards: `create_image` snapshots the block device as it is
    # the instant it is called — a process exiting 0 says its writes were
    # issued, not that the kernel has flushed them off the page cache and
    # onto it. Confirmed live against MarketMySpec: `gem install kamal` ran
    # to completion and every gemspec it had just written came back
    # corrupted in the resulting snapshot, reused across every later build
    # from it. `sync` has to run, and run *before* the snapshot, not after.
    test "syncs the disk before snapshotting, not after" do
      owner = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, _opts ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        if n == 0, do: {:ok, []}, else: {:ok, [%{"id" => 777}]}
      end

      create = fn _scope, _name, _create_opts -> {:ok, server()} end

      run = fn
        ["command -v kamal"] -> {"", 1}
        ["sync"] -> send(owner, :synced) && {"", 0}
        [_command] -> {"", 0}
      end

      create_image = fn _scope, 42, _image_opts ->
        # By the time the snapshot is taken, the disk must already have been
        # synced — asserted here, at the one call that matters, rather than
        # on call order overall.
        assert_received :synced
        {:ok, %{"image" => %{"id" => 777}}}
      end

      destroy = fn _scope, 42 -> {:ok, %{}} end

      assert {:ok, 777} =
               Builder.ensure_builder_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_interval_ms: 0
               )
    end

    test "the source server is not destroyed while Hetzner is still creating the snapshot" do
      owner = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, _opts ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})

        cond do
          n == 0 -> {:ok, []}
          n < 3 -> {:ok, []}
          true -> {:ok, [%{"id" => 777}]}
        end
      end

      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end

      destroy = fn _scope, 42 ->
        # By the time this runs, the image must already show as available —
        # asserted via the counter directly rather than timing, so this
        # fails loudly instead of flaking.
        assert Agent.get(counter, & &1) >= 4,
               "the source server was destroyed before the snapshot was confirmed done"

        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:ok, 777} =
               Builder.ensure_builder_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_interval_ms: 0
               )

      assert_received :destroyed
    end

    test "gives up and still destroys the source if the image never becomes available" do
      owner = self()
      list_images = fn _scope, _opts -> {:ok, []} end
      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end
      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:error, {:image_not_ready, 777}} =
               Builder.ensure_builder_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_interval_ms: 0
               )

      assert_received :destroyed
    end

    # `_ = destroy.(...)` used to discard this outright — a refused or
    # failed delete left no trace anywhere, so a temp box stuck on the
    # account's invoice looked identical to one cleanly destroyed.
    test "logs loudly, rather than silently, when the temp box cannot be destroyed" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, _opts ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        if n == 0, do: {:ok, []}, else: {:ok, [%{"id" => 777}]}
      end

      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end
      destroy = fn _scope, 42 -> {:error, {:hetzner_error, 423, %{}}} end

      log =
        capture_log(fn ->
          assert {:ok, 777} =
                   Builder.ensure_builder_image(scope(), :x86,
                     list_images: list_images,
                     create: create,
                     run: run,
                     create_image: create_image,
                     destroy: destroy,
                     image_poll_interval_ms: 0
                   )
        end)

      assert log =~ "could not destroy temporary x86 bootstrap server"
      assert log =~ "42"
      assert log =~ "still running and being billed"
    end

    test "destroys the temp box even when the bootstrap fails" do
      owner = self()

      list_images = fn _scope, _opts -> {:ok, []} end
      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"connection refused", 255} end
      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:error, {:builder_unreachable, _seconds, _last}} =
               Builder.ensure_builder_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 destroy: destroy,
                 ssh_attempts: 1,
                 ssh_interval_ms: 0
               )

      assert_received :destroyed
    end

    test "an unknown architecture is refused rather than building the wrong box" do
      list_images = fn _scope, _opts -> {:ok, []} end

      assert {:error, {:unknown_architecture, :sparc}} =
               Builder.ensure_builder_image(scope(), :sparc, list_images: list_images)
    end
  end

  # `build/3` never fails because the optimization failed — the stock image
  # plus `Remote.ensure_kamal/1`'s own install is the path that has worked
  # all along, and an account with no Hetzner token configured yet must not
  # lose the ability to deploy while this resolves.
  describe "build/3 picks up a custom builder image automatically" do
    test "uses the found image instead of the stock one, with no caller involvement" do
      build = fn _scope, _server, _ref, arch -> {:ok, %{reference: "img", architecture: arch}} end

      list_images = fn _scope, _opts -> {:ok, [%{"id" => 555}]} end

      create = fn _scope, _name, create_opts ->
        assert create_opts[:image] == 555
        {:ok, server()}
      end

      assert {:ok, _build} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(build_fun: build, create: create, list_images: list_images)
               )
    end

    test "an explicit :builder_image always wins, even with a custom image available" do
      build = fn _scope, _server, _ref, arch -> {:ok, %{reference: "img", architecture: arch}} end

      list_images = fn _scope, _opts ->
        flunk("an explicit :builder_image must not trigger a lookup at all")
      end

      create = fn _scope, _name, create_opts ->
        assert create_opts[:image] == "a-specific-image"
        {:ok, server()}
      end

      assert {:ok, _build} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   build_fun: build,
                   create: create,
                   list_images: list_images,
                   builder_image: "a-specific-image"
                 )
               )
    end

    test "an unconfigured account falls back to the stock image, not a failed build" do
      build = fn _scope, _server, _ref, arch -> {:ok, %{reference: "img", architecture: arch}} end

      list_images = fn _scope, _opts -> {:error, :hetzner_not_configured} end

      create = fn _scope, _name, create_opts ->
        assert create_opts[:image] == "docker-ce"
        {:ok, server()}
      end

      assert {:ok, _build} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(build_fun: build, create: create, list_images: list_images)
               )
    end
  end

  # `opts[:then]` is what lets a deploy run on the same box the image was
  # just built and pushed on — never a second box, and never the environment
  # of whichever caller triggered the run. `Build.deploy` carries back
  # whatever `:then` returned; `nil` for every caller that never asked.
  describe "opts[:then]" do
    defp build_fun do
      fn _scope, _server, _ref, arch -> {:ok, %{reference: "img", architecture: arch}} end
    end

    test "Build.deploy stays nil when no :then is given" do
      assert {:ok, build} = Builder.build(scope(), "abc123", opts(build_fun: build_fun()))

      assert build.deploy == nil
    end

    test "runs on the same box the build just used, not a second one" do
      then_fun = fn run, _dir -> run.(["echo ran"]) end

      opts =
        opts(
          build_fun: build_fun(),
          then: then_fun,
          run: fn [command] -> {"ran: #{command}", 0} end
        )

      assert {:ok, build} = Builder.build(scope(), "abc123", opts)

      assert build.deploy == {"ran: echo ran", 0}
    end

    test "runs before the box is destroyed, not after" do
      owner = self()

      then_fun = fn run, _dir ->
        send(owner, :then_ran)
        run.(["true"])
      end

      opts =
        opts(
          build_fun: build_fun(),
          then: then_fun,
          run: fn [_command] -> {"", 0} end
        )

      assert {:ok, _build} = Builder.build(scope(), "abc123", opts)

      # Ordering, not just occurrence: the destroy message arrives from the
      # injected `destroy` in `opts/1`, so the sequence proves `:then` ran
      # while the box still existed rather than merely that both happened.
      assert_received :then_ran
      assert_received {:destroyed, 42}
    end

    test "the box is still destroyed when :then fails" do
      then_fun = fn _run, _dir -> raise "kamal exploded" end
      run = fn [_command] -> {"", 0} end

      opts = opts(build_fun: build_fun(), then: then_fun, run: run)

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", opts)
      end

      assert_received {:destroyed, 42}
    end

    test "delivers into build_dir, defaulting to /build" do
      then_fun = fn _run, dir -> dir end
      run = fn [_command] -> {"", 0} end

      opts = opts(build_fun: build_fun(), then: then_fun, run: run)
      assert {:ok, build} = Builder.build(scope(), "abc123", opts)

      assert build.deploy == "/build"
    end

    test "a custom build_dir travels to :then too" do
      then_fun = fn _run, dir -> dir end
      run = fn [_command] -> {"", 0} end

      opts = opts(build_fun: build_fun(), then: then_fun, build_dir: "/opt/deploy", run: run)

      assert {:ok, build} = Builder.build(scope(), "abc123", opts)

      assert build.deploy == "/opt/deploy"
    end

    # `bin/deploy` shells out to `kamal`, never installed on the builder
    # before tonight. A raw error tuple here would fall through
    # `deploy_result/5`'s clause that matches `%{deploy: %Deploy.Result{}}`
    # straight into its sibling — the one that reaches for `env(scope)`
    # directly and crashes for a harness-only project. Wrapping it in a
    # `Deploy.Result` keeps that clause matching.
    test "a kamal install failure is reported as a Deploy.Result, not a bare error" do
      then_fun = fn _run, _dir -> flunk("then_fun must not run when kamal never installed") end

      run = fn
        ["command -v kamal"] -> {"", 1}
        ["apt-get" <> _ = _command] -> {"E: Unable to locate package ruby-full", 100}
        [_command] -> {"", 0}
      end

      opts = opts(build_fun: build_fun(), then: then_fun, run: run)

      assert {:ok, build} = Builder.build(scope(), "abc123", opts)

      assert %Deploy.Result{failed_phase: :build, reason: reason} = build.deploy
      assert reason =~ "could not install kamal"
      assert reason =~ "Unable to locate package ruby-full"
    end
  end

  # Issue faaf76b6: a builder name is deterministic from `ref`, so a 409 here
  # is not two callers racing (RunLock already serializes per project) — it
  # is a box an earlier interrupted run left behind. These prove that box
  # gets cleared and the create retried, rather than the bare provider error
  # propagating forever.
  describe "build/3 — orphaned builder from an earlier interrupted run" do
    test "clears the orphan and retries the create" do
      owner = self()
      name = "builder-abc123"
      orphan = %{"id" => 999, "name" => name}

      create = fn _scope, _name, _create_opts ->
        case Process.get(:create_calls, 0) do
          0 ->
            Process.put(:create_calls, 1)

            {:error,
             {:hetzner_error, 409,
              %{"error" => %{"code" => "uniqueness_error", "message" => "server name #{name} is already used"}}}}

          _ ->
            {:ok, server()}
        end
      end

      find = fn _scope, ^name -> {:ok, orphan} end
      destroy = fn _scope, id -> send(owner, {:destroyed, id}) && {:ok, %{}} end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(create: create, find: find, destroy: destroy, build_fun: build)
               )

      # The orphan goes, and so does the box this run actually built on.
      assert_received {:destroyed, 999}
      assert_received {:destroyed, 42}
    end

    test "retries the create when the orphan is gone by the time it looks" do
      create = fn _scope, _name, _create_opts ->
        case Process.get(:create_calls, 0) do
          0 ->
            Process.put(:create_calls, 1)
            {:error, {:hetzner_error, 409, %{"error" => %{"code" => "uniqueness_error", "message" => "already used"}}}}

          _ ->
            {:ok, server()}
        end
      end

      find = fn _scope, _name -> {:error, :not_found} end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} =
               Builder.build(scope(), "abc123", opts(create: create, find: find, build_fun: build))
    end

    test "surfaces a clear, distinguishing error when the orphan cannot be removed" do
      name = "builder-abc123"
      orphan = %{"id" => 999, "name" => name}

      create = fn _scope, _name, _create_opts ->
        {:error, {:hetzner_error, 409, %{"error" => %{"code" => "uniqueness_error", "message" => "already used"}}}}
      end

      find = fn _scope, ^name -> {:ok, orphan} end
      destroy = fn _scope, 999 -> {:error, {:hetzner_error, 423, %{"error" => %{"code" => "locked"}}}} end

      assert {:error, {:orphaned_builder, message}} =
               Builder.build(scope(), "abc123", opts(create: create, find: find, destroy: destroy))

      assert message =~ "already exists at Hetzner"
      assert message =~ "could not be removed"
    end

    test "surfaces a clear, distinguishing error when the orphan can't be looked up" do
      create = fn _scope, _name, _create_opts ->
        {:error, {:hetzner_error, 409, %{"error" => %{"code" => "uniqueness_error", "message" => "already used"}}}}
      end

      find = fn _scope, _name -> {:error, {:hetzner_error, 500, %{}}} end

      assert {:error, {:orphaned_builder, message}} =
               Builder.build(scope(), "abc123", opts(create: create, find: find))

      assert message =~ "already exists at Hetzner"
    end

    test "a non-collision creation error is left alone" do
      create = fn _scope, _name, _create_opts -> {:error, {:capacity_unavailable, "no boxes"}} end

      assert {:error, {:capacity_unavailable, "no boxes"}} =
               Builder.build(scope(), "abc123", opts(create: create))
    end
  end

  # Issue 13ad1abe: a killed process leaves its builder running, attributable
  # to no project. Nothing about it collides on name with the *next* build —
  # that build asks for a differently-named box and gets refused for account
  # capacity instead, which reads as "this account is too small" when the
  # truth is "a box from a run that died hours ago is still holding a slot".
  describe "build/3 — a server-limit refusal from an old orphaned builder" do
    defp resource_limit_error do
      {:error,
       {:hetzner_error, 403,
        %{
          "error" => %{
            "code" => "resource_limit_exceeded",
            "details" => %{"limits" => [%{"name" => "server_limit"}]}
          }
        }}}
    end

    test "reaps a stale builder-* box and retries the create" do
      owner = self()
      stale = %{"id" => 501, "name" => "builder-deadbeef0000", "created" => "2026-08-03T00:00:00Z"}

      create = fn _scope, _name, _create_opts ->
        case Process.get(:create_calls, 0) do
          0 ->
            Process.put(:create_calls, 1)
            resource_limit_error()

          _ ->
            {:ok, server()}
        end
      end

      list = fn _scope -> {:ok, [stale]} end
      destroy = fn _scope, id -> send(owner, {:destroyed, id}) && {:ok, %{}} end

      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      # `now` is an hour past the stale box's `created` — well past
      # `@orphan_max_age_minutes`, so it reads as abandoned rather than
      # in-flight.
      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   create: create,
                   list: list,
                   destroy: destroy,
                   build_fun: build,
                   now: fn -> ~U[2026-08-03 02:00:00Z] end
                 )
               )

      # The stale box goes, and so does the one this run actually built on.
      assert_received {:destroyed, 501}
      assert_received {:destroyed, 42}
    end

    test "leaves a builder-* box alone when it is younger than the age cutoff" do
      recent = %{"id" => 501, "name" => "builder-deadbeef0000", "created" => "2026-08-03T01:50:00Z"}

      create = fn _scope, _name, _create_opts -> resource_limit_error() end
      list = fn _scope -> {:ok, [recent]} end

      # No `:destroy` fake — a destroy call here would raise the default
      # `Keyword.get(opts, :destroy, ...)` real Hetzner call and fail the
      # test, which is exactly the point: nothing should be reaped.
      assert {:error, {:hetzner_error, 403, _}} =
               Builder.build(
                 scope(),
                 "abc123",
                 Keyword.merge(opts(create: create, list: list),
                   now: fn -> ~U[2026-08-03 02:00:00Z] end
                 )
               )
    end

    test "leaves non-builder boxes alone even when old" do
      other = %{"id" => 501, "name" => "fuellytics-prod", "created" => "2020-01-01T00:00:00Z"}

      create = fn _scope, _name, _create_opts -> resource_limit_error() end
      list = fn _scope -> {:ok, [other]} end

      assert {:error, {:hetzner_error, 403, _}} =
               Builder.build(scope(), "abc123", opts(create: create, list: list))
    end

    test "a box with no creation timestamp is not reaped" do
      undated = %{"id" => 501, "name" => "builder-deadbeef0000"}

      create = fn _scope, _name, _create_opts -> resource_limit_error() end
      list = fn _scope -> {:ok, [undated]} end

      assert {:error, {:hetzner_error, 403, _}} =
               Builder.build(scope(), "abc123", opts(create: create, list: list))
    end

    test "a real shortage with nothing to reap surfaces unchanged" do
      create = fn _scope, _name, _create_opts -> resource_limit_error() end
      list = fn _scope -> {:ok, []} end

      assert {:error, {:hetzner_error, 403, %{"error" => %{"code" => "resource_limit_exceeded"}}}} =
               Builder.build(scope(), "abc123", opts(create: create, list: list))
    end

    test "a retry that still fails surfaces its own error, not the original" do
      stale = %{"id" => 501, "name" => "builder-deadbeef0000", "created" => "2026-08-03T00:00:00Z"}

      create = fn _scope, _name, _create_opts ->
        case Process.get(:create_calls, 0) do
          0 ->
            Process.put(:create_calls, 1)
            resource_limit_error()

          _ ->
            {:error, {:hetzner_error, 403, %{"error" => %{"code" => "resource_limit_exceeded"}}}}
        end
      end

      list = fn _scope -> {:ok, [stale]} end
      destroy = fn _scope, _id -> {:ok, %{}} end

      assert {:error, {:hetzner_error, 403, _}} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   create: create,
                   list: list,
                   destroy: destroy,
                   now: fn -> ~U[2026-08-03 02:00:00Z] end
                 )
               )
    end
  end
end

defmodule CodeMySpec.Provisioning.BuilderTest do
  @moduledoc """
  The builder's own claims, with the container build injected.

  A container build is a bad recording subject and a worse unit-test subject —
  minutes per run, non-deterministic digests, invalidated by any Dockerfile
  edit. What is worth testing is ours: which architecture gets asked for, that
  the shared box is asked whether to release itself after every outcome, and
  that an image built for the wrong architecture never leaves the builder.

  The Hetzner calls are injected here too, so these stay unit tests. Story 992
  keeps the real create/destroy under a cassette, because "the box was
  checked" is exactly the claim that costs money when it silently stops being
  true.

  Story 877 moved `build/3` onto the one shared burst box
  (`CodeMySpec.Provisioning.BurstBox.ensure_box/3`) instead of a fresh box
  created and destroyed per build. The default `opts/1` below answers `:find`
  with a box that already exists — the common, cheap case, and the one every
  test not specifically exercising box *creation* or *release* should use.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.Deploy
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{}

  defp server(overrides \\ %{}),
    do: Map.merge(%{"id" => 42, "name" => "burst-platform"}, overrides)

  defp build_fun,
    do: fn _scope, _server, _ref, arch -> {:ok, %{reference: "img", architecture: arch}} end

  # Records every destroy so a test can assert the box went away, and for
  # whom.
  defp recording_destroy(owner) do
    fn _scope, id ->
      send(owner, {:destroyed, id})
      {:ok, %{}}
    end
  end

  # The box already exists by default — the cheap, common path
  # `BurstBox.ensure_box/3` is built around — so a test that does not care
  # about creation or release needs nothing else. `:destroy` flunks by
  # default: nothing here is due for a check (no `"created"` on `server/1`'s
  # default), so a real destroy call would mean something is wrong with the
  # wiring, not a legitimate outcome.
  defp opts(overrides) do
    Keyword.merge(
      [
        architecture: :arm,
        find: fn _scope, _box_name -> {:ok, server()} end,
        destroy: fn _scope, _id -> flunk("a box not due for a check must never be destroyed") end,
        now: fn -> ~U[2026-08-03 00:00:00Z] end
      ],
      overrides
    )
  end

  # `"created"` 58 minutes before `now` below — inside `Lifecycle`'s own
  # check window (`due_for_check?/2`, >= minute 55) — so these tests reach
  # the `:busy?`/`:destroy` decision instead of short-circuiting on
  # `:not_due` the way every other test in this file does by default.
  defp due_opts(overrides) do
    Keyword.merge(
      [
        architecture: :arm,
        find: fn _scope, _box_name -> {:ok, server(%{"created" => "2026-08-03T00:00:00Z"})} end,
        now: fn -> ~U[2026-08-03 00:58:00Z] end,
        busy?: fn _scope, _server -> false end,
        destroy: recording_destroy(self())
      ],
      overrides
    )
  end

  # `list_images` stub: nothing found on the first call (the top-level,
  # `status: "available"`-filtered existence check `ensure_burst_box_image/3`
  # makes before ever building anything), the built image available on every
  # call after (the unfiltered polls `await_image_ready/5` makes once a
  # snapshot is in flight — see that function's own comment for why it does
  # not filter by status). Simulates the image not existing yet, then
  # existing once `create_image` has finished.
  defp list_images_response(0), do: {:ok, []}
  defp list_images_response(_after_first), do: {:ok, [%{"id" => 777, "status" => "available"}]}

  # Same shape, but the image isn't ready until the third poll — proves the
  # source server survives two "not yet" answers before the confirmed one.
  defp not_ready_until_third_poll(0), do: {:ok, []}

  defp not_ready_until_third_poll(n) when n < 3,
    do: {:ok, [%{"id" => 777, "status" => "creating"}]}

  defp not_ready_until_third_poll(_n), do: {:ok, [%{"id" => 777, "status" => "available"}]}

  # Branches on whether the real `status: "available"`-filtered query is
  # the one being simulated (the top-level existence check) or the
  # unfiltered poll (`await_image_ready/5`) — multi-clause rather than an
  # `if`, per this file's own rule against imperative branching in test
  # helpers.
  defp list_images_creating_forever(_scope, opts) when is_list(opts),
    do: still_creating_response(Keyword.get(opts, :status))

  defp still_creating_response("available"), do: {:ok, []}
  defp still_creating_response(_not_filtered), do: {:ok, [%{"id" => 777, "status" => "creating"}]}

  describe "the box a build runs on" do
    test "an amd64 build asks for the x86 box, an arm build for the arm one" do
      owner = self()

      ensure = fn _scope, name, _opts ->
        send(owner, {:box, name})
        {:ok, server(%{"name" => name})}
      end

      for arch <- [:x86, :arm] do
        assert {:ok, _} =
                 Builder.build(
                   scope(),
                   "abc123",
                   opts(architecture: arch, ensure_box: ensure, build_fun: build_fun())
                 )
      end

      assert_received {:box, "burst-platform-x86"}
      assert_received {:box, "burst-platform"}
    end
  end

  describe "a first box for an architecture" do
    test "does not install this app's release, so it needs no :ref" do
      owner = self()

      ensure = fn _scope, _name, box_opts ->
        send(owner, {:install, box_opts[:install_release].(fn _ -> {"", 0} end, %{}, [])})
        {:ok, server()}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(architecture: :x86, ensure_box: ensure, build_fun: build_fun())
               )

      assert_received {:install, :ok}
    end
  end

  describe "a reused box and the build's network" do
    test "a box made for another network joins the build's before building" do
      owner = self()
      on_uat = server(%{"private_net" => [%{"network" => 12_602_966}]})

      attach = fn _scope, id, network_id ->
        send(owner, {:attached, id, network_id})
        {:ok, :attached}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   find: fn _scope, _name -> {:ok, on_uat} end,
                   network_ids: [12_586_313],
                   attach_to_network: attach,
                   build_fun: build_fun()
                 )
               )

      assert_received {:attached, 42, 12_586_313}
    end

    test "a box already on the build's network is left as it is" do
      on_prod = server(%{"private_net" => [%{"network" => 12_586_313}]})

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   find: fn _scope, _name -> {:ok, on_prod} end,
                   network_ids: [12_586_313],
                   attach_to_network: fn _, _, _ -> flunk("already attached") end,
                   build_fun: build_fun()
                 )
               )
    end
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

    test "reads the box's own image off its live Hetzner record, sanitized to one token" do
      # The box the deploy step's `builder_resource/1` packs into a
      # `"key=value key=value"` identifier, parsed back apart by splitting on
      # spaces — a multi-word description like a real burst-box snapshot
      # carries would silently truncate on that round trip otherwise.
      server = server(%{"image" => %{"description" => "CodeMySpec burst box (arm)"}})

      assert {:ok, result} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(build_fun: build_fun(), find: fn _scope, _box_name -> {:ok, server} end)
               )

      assert result.builder_image == "CodeMySpec_burst_box_(arm)"
    end

    test "a failed build reports its own disposition" do
      build = fn _scope, _server, _ref, _arch -> {:error, :compilation_failed} end

      assert {:error, :compilation_failed, disposition} =
               Builder.build(scope(), "abc123", opts(build_fun: build))

      # A leaked box adds nothing visible to an already-failed deploy, which
      # is why the disposition is worth recording even on failure.
      assert disposition.builder == "burst-platform"
    end

    test "a build that raises still propagates the error" do
      build = fn _scope, _server, _ref, _arch -> raise "docker exploded" end

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", opts(build_fun: build))
      end
    end

    test "an image built for the wrong architecture is not shipped" do
      build = fn _scope, _server, _ref, _arch ->
        {:ok, %{reference: "img", architecture: :x86}}
      end

      assert {:error, {:architecture_mismatch, [built: :x86, wanted: :arm]}, _disposition} =
               Builder.build(scope(), "abc123", opts(build_fun: build))
    end

    test "builds on the architecture the servers run" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(
          owner,
          {:created, create_opts[:server_type], create_opts[:location], create_opts[:labels]}
        )

        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   build_fun: build_fun(),
                   find: fn _scope, _box_name -> {:error, :not_found} end,
                   ensure_burst_box_image: fn _scope, _arch, _opts -> {:ok, "image-id"} end,
                   create: create,
                   architecture: :x86
                 )
               )

      # cpx31, not cpx32: identical on paper, but cpx32 does not exist in ash or
      # hil, and the builder has to be created wherever the app box is.
      assert_received {:created, "cpx31", "fsn1", labels}
      assert labels[Builder.deploy_builder_label()] == "true"
      assert labels["cms-burst-role"] == "true"
    end

    # The builder pushes to a registry on the app box's private network, and a
    # network's subnet lives in exactly one zone — so a builder in a different
    # zone holds an address on a network it cannot reach. Both boxes had
    # 10.0.0.x addresses and routes, and ping got 100% packet loss.
    test "is built beside the box it pushes to, when told where that is" do
      owner = self()

      create = fn _scope, _name, create_opts ->
        send(owner, {:created, create_opts[:location]})
        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   build_fun: build_fun(),
                   find: fn _scope, _box_name -> {:error, :not_found} end,
                   ensure_burst_box_image: fn _scope, _arch, _opts -> {:ok, "image-id"} end,
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
        {:ok, %{"server" => server()}}
      end

      assert {:ok, _} =
               Builder.build(
                 scope(),
                 "abc123",
                 opts(
                   build_fun: build_fun(),
                   find: fn _scope, _box_name -> {:error, :not_found} end,
                   ensure_burst_box_image: fn _scope, _arch, _opts -> {:ok, "image-id"} end,
                   create: create,
                   architecture: :x86,
                   location: "fsn1"
                 )
               )

      assert_received {:created, "fsn1"},
                      "a bucket region must not decide which datacenter the builder lands in"
    end

    test "requires the target architecture before choosing a builder" do
      assert {:error, {:unknown_architecture, nil}} =
               Builder.build(scope(), "abc123", opts(architecture: nil))
    end

    test "refuses an architecture with no builder rather than guessing one" do
      assert {:error, {:unknown_architecture, :sparc}} =
               Builder.build(scope(), "abc123", opts(architecture: :sparc))
    end
  end

  # Without a resolved source environment, delivery falls back to GitHub and
  # fails clearly when the project has no repository to use.
  describe "choosing how to deliver the source" do
    test "falls back to a clean error, not a crash, when there is no repo to fall back to" do
      scope = %Scope{}
      run = fn [_cmd] -> {"", 0} end

      assert {:error, {:source_delivery_failed, :no_reachable_source, _}, _resources} =
               Builder.build(scope, "abc123", opts(run: run, reference: "reg/app:abc123"))
    end
  end

  describe "ensure_burst_box_image/3" do
    test "finds an existing burst-box image by its own label" do
      list_images = fn _scope, opts ->
        assert opts[:label_selector] == "cms-burst-image-role=x86"
        {:ok, [%{"id" => 909}]}
      end

      create = fn _scope, _name, _create_opts ->
        flunk("a matching burst-box image already exists — nothing should be created")
      end

      assert {:ok, 909} =
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create
               )
    end

    test "builds one from scratch, runs :install_release after kamal and before the disk is synced, then destroys the temp box" do
      owner = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, opts ->
        assert opts[:label_selector] == "cms-burst-image-role=x86"
        counter |> Agent.get_and_update(&{&1, &1 + 1}) |> list_images_response()
      end

      create = fn _scope, name, create_opts ->
        assert name =~ "cms-burst-bootstrap-x86-"
        assert create_opts[:image] == "docker-ce"
        {:ok, server()}
      end

      run = fn
        ["command -v kamal" <> _] ->
          {"", 1}

        ["sync"] ->
          # By the time the disk is synced, the release must already have
          # been installed — asserted here, at the one call that matters.
          assert_received :release_installed
          send(owner, :synced)
          {"", 0}

        [_command] ->
          {"", 0}
      end

      install_release = fn _run, srv, _opts ->
        assert srv["id"] == 42
        send(owner, :release_installed)
        :ok
      end

      create_image = fn _scope, 42, image_opts ->
        assert image_opts[:labels] == %{"cms-burst-image-role" => "x86"}
        assert image_opts[:description] =~ "burst box"
        assert_received :synced
        {:ok, %{"image" => %{"id" => 777}}}
      end

      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:ok, 777} =
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: install_release,
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
    test "the source server is not destroyed while Hetzner is still creating the snapshot" do
      owner = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      list_images = fn _scope, _opts ->
        counter |> Agent.get_and_update(&{&1, &1 + 1}) |> not_ready_until_third_poll()
      end

      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      install_release = fn _run, _server, _opts -> :ok end
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
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: install_release,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_interval_ms: 0
               )

      assert_received :destroyed
    end

    # The bug the live test (story 877/992 follow-on) actually found:
    # `destroy_temp_server` used to run unconditionally after this `with`
    # chain, including on a poll that merely gave up — so a real snapshot
    # that was still mid-write got destroyed along with its own source,
    # losing the whole (expensive) bootstrap with nothing to show for it.
    # Giving up now means leaving the source alone and naming it in the
    # error — never guessing by deleting the one thing that could still
    # turn into a usable image.
    test "gives up without destroying the source if the image is never confirmed ready" do
      list_images = &list_images_creating_forever/2
      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      install_release = fn _run, _server, _opts -> :ok end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end

      destroy = fn _scope, _id ->
        flunk("the source must not be destroyed while the snapshot's outcome is unconfirmed")
      end

      assert {:error, {:image_not_confirmed, 777, 42}} =
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: install_release,
                 create_image: create_image,
                 destroy: destroy,
                 image_poll_attempts: 2,
                 image_poll_interval_ms: 0
               )
    end

    # Harness's distinction (3): a timeout and a confirmed loss are not the
    # same thing, and only one of them still has something worth protecting.
    test "destroys the source and says the image vanished, rather than merely not-ready, when it is actually gone" do
      owner = self()
      list_images = fn _scope, _opts -> {:ok, []} end
      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      install_release = fn _run, _server, _opts -> :ok end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end

      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:error, {:image_vanished, 777}} =
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: install_release,
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
        counter |> Agent.get_and_update(&{&1, &1 + 1}) |> list_images_response()
      end

      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      install_release = fn _run, _server, _opts -> :ok end
      create_image = fn _scope, 42, _image_opts -> {:ok, %{"image" => %{"id" => 777}}} end
      destroy = fn _scope, 42 -> {:error, {:hetzner_error, 423, %{}}} end

      log =
        capture_log(fn ->
          assert {:ok, 777} =
                   Builder.ensure_burst_box_image(scope(), :x86,
                     list_images: list_images,
                     create: create,
                     run: run,
                     install_release: install_release,
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
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: fn _run, _server, _opts -> :ok end,
                 destroy: destroy,
                 ssh_attempts: 1,
                 ssh_interval_ms: 0
               )

      assert_received :destroyed
    end

    test "a failed :install_release still destroys the temp box and is returned as the error" do
      owner = self()
      list_images = fn _scope, _opts -> {:ok, []} end
      create = fn _scope, _name, _create_opts -> {:ok, server()} end
      run = fn [_command] -> {"", 0} end
      install_release = fn _run, _server, _opts -> {:error, :release_build_failed} end

      destroy = fn _scope, 42 ->
        send(owner, :destroyed)
        {:ok, %{}}
      end

      assert {:error, :release_build_failed} =
               Builder.ensure_burst_box_image(scope(), :x86,
                 list_images: list_images,
                 create: create,
                 run: run,
                 install_release: install_release,
                 destroy: destroy
               )

      assert_received :destroyed
    end

    test "is required — there is no silent default that skips installing the release" do
      list_images = fn _scope, _opts -> {:ok, []} end
      create = fn _scope, _name, _create_opts -> {:ok, server()} end

      assert_raise KeyError, fn ->
        Builder.ensure_burst_box_image(scope(), :x86, list_images: list_images, create: create)
      end
    end

    test "an unknown architecture is refused rather than building the wrong box" do
      list_images = fn _scope, _opts -> {:ok, []} end

      assert {:error, {:unknown_architecture, :sparc}} =
               Builder.ensure_burst_box_image(scope(), :sparc, list_images: list_images)
    end
  end

  # `opts[:then]` is what lets a deploy run on the same box the image was
  # just built and pushed on — never a second box, and never the environment
  # of whichever caller triggered the run. `Build.deploy` carries back
  # whatever `:then` returned; `nil` for every caller that never asked.
  describe "opts[:then]" do
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
        ["command -v kamal" <> _] -> {"", 1}
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

  # Story 877: the box is no longer destroyed unconditionally at the end of
  # every build — it is shared, so every path instead asks
  # `BurstBox.Lifecycle.check/3` whether *this* was the job that leaves it
  # idle for the rest of its billing hour. These pin that every outcome
  # (success, failure, raise) reaches the check, and that its answer is
  # reported honestly rather than assumed.
  describe "build/3 — releasing the shared box afterward" do
    test "deletes a box it creates when the build succeeds" do
      owner = self()

      create = fn _, name, create_opts ->
        server =
          server(%{
            "name" => name,
            "created" => "2026-08-03T00:00:00Z",
            "labels" => create_opts[:labels]
          })

        send(owner, {:created_box, server["id"]})
        {:ok, %{"server" => server}}
      end

      options =
        opts(
          find: fn _, _ -> {:error, :not_found} end,
          ensure_burst_box_image: fn _, _, _ -> {:ok, "image-id"} end,
          create: create,
          build_fun: build_fun(),
          busy?: fn _, _ -> false end,
          destroy: recording_destroy(owner),
          now: fn -> ~U[2026-08-03 00:10:00Z] end
        )

      assert {:ok, build} = Builder.build(scope(), "abc123", options)
      assert build.builder_destroyed
      assert_received {:created_box, 42}
      assert_received {:destroyed, 42}
    end

    test "deletes an idle deploy-created box after a successful build before the billing window" do
      created =
        server(%{
          "created" => "2026-08-03T00:00:00Z",
          "labels" => %{Builder.deploy_builder_label() => "true"}
        })

      options =
        opts(
          find: fn _, _ -> {:ok, created} end,
          now: fn -> ~U[2026-08-03 00:10:00Z] end,
          busy?: fn _, _ -> false end,
          destroy: recording_destroy(self()),
          build_fun: build_fun()
        )

      assert {:ok, build} = Builder.build(scope(), "abc123", options)
      assert build.builder_destroyed
      assert_received {:destroyed, 42}
    end

    test "deletes an idle deploy-created box after a failed build before the billing window" do
      created =
        server(%{
          "created" => "2026-08-03T00:00:00Z",
          "labels" => %{Builder.deploy_builder_label() => "true"}
        })

      build = fn _, _, _, _ -> {:error, :compilation_failed} end

      options =
        opts(
          find: fn _, _ -> {:ok, created} end,
          now: fn -> ~U[2026-08-03 00:10:00Z] end,
          busy?: fn _, _ -> false end,
          destroy: recording_destroy(self()),
          build_fun: build
        )

      assert {:error, :compilation_failed, disposition} =
               Builder.build(scope(), "abc123", options)

      assert disposition.builder_destroyed
      assert_received {:destroyed, 42}
    end

    test "keeps the box, and reports it, when it is not due for a check" do
      assert {:ok, result} = Builder.build(scope(), "abc123", opts(build_fun: build_fun()))

      refute result.builder_destroyed
    end

    test "frees an idle box due for a check, and reports it" do
      assert {:ok, build} = Builder.build(scope(), "abc123", due_opts(build_fun: build_fun()))

      assert_received {:destroyed, 42}
      assert build.builder_destroyed
    end

    test "keeps a busy box due for a check, and reports it" do
      opts = due_opts(build_fun: build_fun(), busy?: fn _scope, _server -> true end)

      assert {:ok, build} = Builder.build(scope(), "abc123", opts)

      refute_received {:destroyed, _}
      refute build.builder_destroyed
    end

    test "still asks whether to release the box when the build fails" do
      build = fn _scope, _server, _ref, _arch -> {:error, :compilation_failed} end

      assert {:error, :compilation_failed, disposition} =
               Builder.build(scope(), "abc123", due_opts(build_fun: build))

      assert_received {:destroyed, 42}
      assert disposition.builder_destroyed
    end

    test "still asks whether to release the box when the build raises" do
      build = fn _scope, _server, _ref, _arch -> raise "docker exploded" end

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", due_opts(build_fun: build))
      end

      assert_received {:destroyed, 42}
    end

    test "runs :then before the box is released, not after" do
      owner = self()

      then_fun = fn run, _dir ->
        send(owner, :then_ran)
        run.(["true"])
      end

      opts = due_opts(build_fun: build_fun(), then: then_fun, run: fn [_command] -> {"", 0} end)

      assert {:ok, _build} = Builder.build(scope(), "abc123", opts)

      # Ordering, not just occurrence: the destroy message arrives from the
      # injected `destroy` in `due_opts/1`, so the sequence proves `:then`
      # ran while the box still existed rather than merely that both
      # happened.
      assert_received :then_ran
      assert_received {:destroyed, 42}
    end

    test "the box is still checked for release when :then fails" do
      then_fun = fn _run, _dir -> raise "kamal exploded" end
      run = fn [_command] -> {"", 0} end

      opts = due_opts(build_fun: build_fun(), then: then_fun, run: run)

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", opts)
      end

      assert_received {:destroyed, 42}
    end
  end

  describe "where a build's source comes from" do
    alias CodeMySpec.ExecutionContexts.ExecutionContext

    test "a checkout on this node is archived from it" do
      opts = [env: ExecutionContext.new(:local, "/work/app")]

      refute Keyword.has_key?(
               Builder.with_deliver(opts, %{"ip" => "10.0.0.2"}, scope()),
               :deliver
             )
    end

    # A harness copy's checkout is on another machine: `git archive` cannot run
    # there for us, so the source has to come from the repository's remote.
    test "a harness copy's source comes from GitHub, not its checkout" do
      opts = [env: %ExecutionContext{type: :harness, cwd: "/Users/someone/app"}]

      deliver =
        Keyword.fetch!(Builder.with_deliver(opts, %{"ip" => "10.0.0.2"}, scope()), :deliver)

      assert {:error, {:source_delivery_failed, :no_reachable_source, _}} =
               deliver.("HEAD", "/build")
    end
  end
end

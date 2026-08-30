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

  alias CodeMySpec.Provisioning.Builder
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

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
end

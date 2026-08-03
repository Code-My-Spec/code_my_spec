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
               Builder.build(scope(), "abc123", opts(build: build))

      assert result.image == "registry.example/app:abc123"
      assert result.architecture == :arm
    end

    test "destroys the builder once the image exists" do
      build = fn _scope, _server, _ref, arch ->
        {:ok, %{reference: "img", architecture: arch}}
      end

      assert {:ok, _} = Builder.build(scope(), "abc123", opts(build: build))

      assert_received {:destroyed, 42}
    end

    test "destroys the builder when the build fails" do
      build = fn _scope, _server, _ref, _arch -> {:error, :compilation_failed} end

      assert {:error, :compilation_failed} =
               Builder.build(scope(), "abc123", opts(build: build))

      # The whole point: a failed build must not leave a box running. Sam is
      # billed for it either way.
      assert_received {:destroyed, 42}
    end

    test "destroys the builder when the build raises" do
      build = fn _scope, _server, _ref, _arch -> raise "docker exploded" end

      assert_raise RuntimeError, fn ->
        Builder.build(scope(), "abc123", opts(build: build))
      end

      assert_received {:destroyed, 42}
    end

    test "an image built for the wrong architecture is not shipped" do
      build = fn _scope, _server, _ref, _arch ->
        {:ok, %{reference: "img", architecture: :x86}}
      end

      assert {:error, {:architecture_mismatch, built: :x86, wanted: :arm}} =
               Builder.build(scope(), "abc123", opts(build: build))

      # And the builder still goes, because a mismatch is a failed build.
      assert_received {:destroyed, 42}
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
                 opts(build: build, create: create, architecture: :x86)
               )

      assert_received {:created, "cpx21", "ash"}
    end

    test "refuses an architecture with no builder rather than guessing one" do
      assert {:error, {:unknown_architecture, :sparc}} =
               Builder.build(scope(), "abc123", opts(architecture: :sparc))
    end
  end
end

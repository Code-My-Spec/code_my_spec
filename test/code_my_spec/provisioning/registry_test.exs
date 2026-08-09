defmodule CodeMySpec.Provisioning.RegistryTest do
  @moduledoc """
  The registry's addressing and its retention.

  Bucket creation and lifecycle go through `Storage`, which story 968 already
  proves against the real provider — including the Ceph quirks in the lifecycle
  XML. What is worth testing here is what this module decides: where an image
  is addressed from, that the address is the same at both ends of a transfer
  between two machines, that each project's images land in its own bucket, and
  that retention applies to the blobs rather than to everything.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Users.Scope

  defp scope(name \\ "Sam's App"), do: %Scope{active_project: %{name: name}}

  describe "reference/3" do
    test "addresses an image at the registry, not at GitHub" do
      assert {:ok, reference} =
               Registry.reference(scope(), "abc123", registry_host: "registry.example.com")

      assert reference == "registry.example.com/sam-s-app:abc123"

      # The claim behind 8240: nothing in the deploy path points at GitHub.
      refute reference =~ "ghcr.io"
      refute reference =~ "github"
    end

    # Was "refuses to build a reference nobody can pull", asserting
    # `{:error, :no_registry_host}` when nothing configured a host. That was
    # right for a shared registry, whose address is a deployment fact somebody
    # has to supply — and in practice nobody ever did, so the deploy step
    # failed with that error the first time a drill reached it.
    #
    # Per-customer, the address is not a deployment fact. The registry is on
    # the box doing the pulling, so loopback is the answer everywhere and there
    # is nothing left to leave unset.
    test "needs no configuration, because the registry is on the box asking" do
      assert {:ok, reference} = Registry.reference(scope(), "abc123")

      assert reference == "localhost:5000/sam-s-app:abc123"
    end

    # Push and pull happen on different machines — the builder and the app's
    # server — and a reference is baked into the image, so it cannot differ
    # between them. Loopback plus a tunnel is what makes one string correct in
    # both places.
    test "the same string serves the push and the pull" do
      assert {:ok, pushed} = Registry.reference(scope(), "abc123")
      assert {:ok, pulled} = Registry.reference(scope(), "abc123")

      assert pushed == pulled
      assert pushed =~ "localhost:#{Registry.port()}/"
    end

    test "a project with no name cannot name a repository" do
      assert {:error, :no_project} =
               Registry.reference(%Scope{}, "abc123", registry_host: "registry.example.com")
    end

    # The deploy step hands its whole opts list to this, and `:host` there is
    # the app's own hostname. Reading it would address every image at the
    # customer's domain and send the deploy to pull from itself — which looks
    # like a working reference right up until the pull.
    test "the deploy's own host is not mistaken for the registry's" do
      assert {:ok, reference} =
               Registry.reference(scope(), "abc123",
                 host: "sams-app.com",
                 registry_host: "registry.example.com"
               )

      assert reference == "registry.example.com/sam-s-app:abc123"
      refute reference =~ "sams-app.com"
    end
  end

  # The reason the shared registry was abandoned. One store holding every
  # customer's application images is a cross-tenant boundary, and isolation is
  # the acceptance criterion for the multi-tenant work — a bug in one
  # registry's auth would leak everyone's proprietary code as a pullable image.
  describe "each project's images live in its own bucket" do
    test "two projects do not share a bucket" do
      refute Registry.bucket_name(scope("Sam's App")) ==
               Registry.bucket_name(scope("Dana's App"))
    end

    test "the bucket is named after the project" do
      assert Registry.bucket_name(scope("Sam's App")) == "sam-s-app-registry"
    end

    # Not per environment, unlike `Storage.bucket_name/2`. Promoting the exact
    # image UAT proved is the point of the release process; separate registries
    # would force a rebuild to promote, which is how a promotion ships
    # something that was never tested.
    test "one registry serves every environment" do
      bucket = Registry.bucket_name(scope("Sam's App"))

      refute bucket =~ "uat"
      refute bucket =~ "prod"
    end

    test "an unnamed project refuses rather than sharing a generic bucket" do
      assert_raise ArgumentError, ~r/no name/, fn ->
        Registry.bucket_name(%Scope{})
      end
    end
  end

  describe "retention" do
    test "keeps images long enough to roll back, and not forever" do
      assert Registry.retention_days([]) == 30
      assert Registry.retention_days(retention_days: 7) == 7
    end

    test "applies to the blobs, which is where the space goes" do
      # A manifest pointing at expired blobs is already unusable, so expiring
      # blobs is what actually reclaims anything.
      assert Registry.blobs_prefix() =~ "blobs"
    end
  end
end

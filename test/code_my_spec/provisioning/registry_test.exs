defmodule CodeMySpec.Provisioning.RegistryTest do
  @moduledoc """
  The registry's addressing and its retention.

  Bucket creation and lifecycle go through `Storage`, which story 968 already
  proves against the real provider — including the Ceph quirks in the lifecycle
  XML. What is worth testing here is what this module decides: where an image
  is addressed from, that retention applies to the blobs rather than to
  everything, and that a missing registry host is an error rather than a
  reference nobody can pull.
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

    test "refuses to build a reference nobody can pull" do
      # A reference with no host is worse than an error: it looks like an
      # address, and the deploy fails at pull time naming a registry that was
      # never configured.
      assert {:error, :no_registry_host} = Registry.reference(scope(), "abc123")
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

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

  # Same shape as `Builder.Remote`'s tests: `:run` takes the command and
  # returns `{output, status}`, so what we ask the box to do is assertable and
  # running it is not. Starting a real registry would make this a network test
  # and prove nothing about the command.
  describe "serve/2" do
    defp recorder(owner, status \\ 0) do
      fn [command] ->
        send(owner, {:ran, command})
        {"", status}
      end
    end

    defp creds, do: [access_key_id: "AKIA", secret_access_key: "s3cret", region: "fsn1"]

    defp registry_cred, do: %{username: "cms", password: "pw"}

    defp serve(opts \\ []) do
      Registry.serve(
        scope(),
        Keyword.merge(
          [run: recorder(self()), credentials: creds(), registry_credentials: registry_cred()],
          opts
        )
      )
    end

    test "points the registry at this project's bucket" do
      assert {:ok, %{bucket: "sam-s-app-registry"}} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "REGISTRY_STORAGE_S3_BUCKET='sam-s-app-registry'"
    end

    # Hetzner's object storage is S3-compatible but not S3. A virtual-host
    # style request reaches a bucket that does not exist rather than failing
    # usefully, which is the failure mode this flag exists to avoid.
    test "addresses the bucket path-style, which Hetzner requires" do
      assert {:ok, _} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "REGISTRY_STORAGE_S3_FORCEPATHSTYLE='true'"
      assert command =~ "REGISTRY_STORAGE_S3_REGIONENDPOINT='https://fsn1.your-objectstorage.com'"
    end

    test "listens on loopback unless told otherwise" do
      assert {:ok, %{bind: "127.0.0.1", port: 5000}} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "-p 127.0.0.1:5000:5000"
    end

    # The one knob the topology turns. A builder on another machine has to
    # reach this port somehow, and where it binds decides whether that is a
    # tunnel or a private address.
    test "binds where it is told" do
      assert {:ok, %{bind: "10.0.0.2"}} = serve(bind: "10.0.0.2")

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "-p 10.0.0.2:5000:5000"
    end

    # Setup runs more than once, so the second run has to converge rather than
    # fail on a container name that is already taken.
    test "replaces the container rather than colliding with it" do
      assert {:ok, _} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "docker rm -f cms-registry"
      assert command =~ "docker run -d --name cms-registry"
    end

    # A deploy that cannot pull is a deploy that cannot roll back, and the
    # moment you need a rollback is not the moment to find the registry went
    # away with the last reboot.
    test "survives a reboot of the box it shares with the app" do
      assert {:ok, _} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}
      assert command =~ "--restart always"
    end

    # Docker assumes HTTPS for every registry but `localhost`, and this one
    # speaks plain HTTP on a private address. Without the exemption the push
    # fails with `context deadline exceeded` — a timeout, which reads as an
    # unreachable host rather than a protocol disagreement.
    test "the box is told the registry speaks plain HTTP" do
      assert {:ok, _} = serve(bind: "10.0.0.2")

      assert_received {:ran, trust}

      assert trust =~ "insecure-registries"
      assert trust =~ "10.0.0.2:5000"

      # Restarting Docker stops everything on the box, which on the app's
      # server is the app. Only when the file actually changes.
      assert trust =~ "grep -qF"
      assert trust =~ "systemctl restart docker"
    end

    # `docker run -d` returning 0 means the container was created, not that it
    # is up. A bind to an address the interface does not carry yet fails after
    # the daemon has answered, and the container exits behind a successful
    # command — the push then times out against nothing, which reads as an
    # unreachable host rather than a registry that died on startup.
    test "asks the registry itself before reporting it up" do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert {:ok, _} = Registry.serve(scope(), run: run, credentials: creds(), registry_credentials: registry_cred())

      assert_received {:ran, _trust}
      assert_received {:ran, _start}
      assert_received {:ran, probe}

      assert probe =~ "curl"
      assert probe =~ "/v2/"
    end

    test "a container that starts and dies is not a running registry" do
      run = fn
        ["curl" <> _] -> {"", 7}
        ["docker logs" <> _] -> {"level=fatal msg=\"cannot bind\"", 0}
        [_] -> {"", 0}
      end

      assert {:error, {:registry_not_listening, "127.0.0.1:5000", logs}} =
               Registry.serve(scope(),
                 run: run,
                 credentials: creds(),
                 registry_credentials: registry_cred(),
                 registry_attempts: 2
               )

      # The container's own logs, not a timeout. The reason is in them, and a
      # drill costs ten minutes to repeat.
      assert logs =~ "cannot bind"
    end

    # kamal refuses to render a config without a registry password and then
    # logs in with it, so an unauthenticated registry is not an option even on
    # a private address. The credential is real rather than a placeholder,
    # because "only reachable from inside" is a property of today's firewall
    # rather than of the registry.
    test "the registry requires a credential" do
      assert {:ok, _} = serve()

      assert_received {:ran, _trust}
      assert_received {:ran, command}

      assert command =~ "REGISTRY_AUTH=htpasswd"
      assert command =~ "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd"

      # bcrypt, because `distribution` accepts nothing else — and generated
      # here because `htpasswd` is not installed on the box.
      assert command =~ "cms:$2b$"

      refute command =~ "password='pw'",
             "the password must reach the box hashed, not in the clear"
    end

    test "a registry that will not start is an error, not a success" do
      assert {:error, {:registry_start_failed, 125, _}} =
               serve(run: recorder(self(), 125))
    end

    test "without storage credentials there is nothing to back it with" do
      assert {:error, :no_storage_credentials} =
               Registry.serve(scope(), run: recorder(self()), credentials: :none, registry_credentials: registry_cred())

      refute_received {:ran, _}
    end
  end
end

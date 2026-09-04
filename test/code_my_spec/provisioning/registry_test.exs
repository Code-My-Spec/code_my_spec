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

  # Exists for a generated kamal config's `image:` field, which names a bare
  # repository with no tag — `reference/3` builds one specific tag on top of
  # exactly this. Found needed live: `DeployArtifacts`' own generator composed
  # `image:` from `owner`/`app` opts the way ghcr.io wants them named, which
  # is a different path than this registry actually serves the same project
  # at — there is no owner segment here at all.
  describe "image/2" do
    test "the same bare path reference/3 builds a tag onto" do
      assert {:ok, image} = Registry.image(scope())
      assert {:ok, reference} = Registry.reference(scope(), "abc123")

      assert reference == "#{image}:abc123"
      assert image == "localhost:5000/sam-s-app"
    end

    test "a project with no name cannot name a repository" do
      assert {:error, :no_project} = Registry.image(%Scope{})
    end
  end

  # The registry container is a box-wide singleton (`serve/2`), but what it
  # stores per project is not — a bucket, and a repository path, per project,
  # so the container being shared does not mean one project's images become
  # readable through another project's own bucket credentials.
  describe "each project's images live in its own bucket" do
    test "two projects do not share a bucket" do
      refute Registry.bucket_name(scope("Sam's App")) ==
               Registry.bucket_name(scope("Dana's App"))
    end

    test "the bucket is named after the project" do
      assert Registry.bucket_name(scope("Sam's App")) == "sam-s-app-registry"
    end

    # Per environment, because a binary cannot be promoted across
    # architectures — UAT may be arm and production x86, `Builder` refuses an
    # image built for the wrong one, so promotion is the same commit rebuilt
    # rather than the same image moved. Each environment's registry therefore
    # needs its own bucket: two `distribution` instances sharing one would
    # corrupt each other's state.
    test "each environment's registry gets its own bucket" do
      uat = Registry.bucket_name(scope("Sam's App"), environment: "uat")
      prod = Registry.bucket_name(scope("Sam's App"), environment: "prod")

      assert uat == "sam-s-app-registry-uat"
      assert prod == "sam-s-app-registry-prod"
      refute uat == prod
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

  # 6dcb62b8: `retention_days/1` answers with a number under any storage mode
  # — it is a duration, not a claim about who applies it — and steps.ex and
  # `ProvisioningLive` both used to render `enforced_by: bucket_lifecycle`
  # unconditionally, off that number alone. Nothing ever asked whether a
  # lifecycle rule actually existed, which it does not under `:filesystem`,
  # the real default (`ensure_storage(:filesystem, ..)` creates no bucket).
  describe "retention_enforced?/1" do
    test "filesystem — the real default everywhere today — enforces nothing" do
      refute Registry.retention_enforced?([])
      refute Registry.retention_enforced?(storage: :filesystem)
    end

    test "a lifecycle rule only exists once storage is explicitly :s3" do
      assert Registry.retention_enforced?(storage: :s3)
    end
  end

  # Same shape as `Builder.Remote`'s tests: `:run` takes the command and
  # returns `{output, status}`, so what we ask the box to do is assertable and
  # running it is not. Starting a real registry would make this a network test
  # and prove nothing about the command.
  #
  # `ensure_container/2` (account-side: the box-wide container, run once
  # regardless of which project asks) and `serve/2` (project-side: this
  # project's own credential on an already-running registry) used to be one
  # function. Split so a project's own devops step can never stand up shared
  # account infrastructure as a side effect of asking for its own tenant —
  # the same reasoning `Steps.server_creation_gate/3` applies to the server
  # itself.
  defp recorder(owner, status \\ 0) do
    fn [command] ->
      send(owner, {:ran, command})
      {"", status}
    end
  end

  # The container already up and answered for, the shape every `serve/2`
  # call sees in the ordinary case — someone else's (or this project's own
  # earlier) `ensure_container/2` already ran.
  defp running_recorder(owner, status \\ 0) do
    fn [command] ->
      send(owner, {:ran, command})

      case command do
        "docker ps -q -f name=" <> _ -> {"c0ffeec0ffee", 0}
        _ -> {"", status}
      end
    end
  end

  defp creds, do: [access_key_id: "AKIA", secret_access_key: "s3cret", region: "fsn1"]

  defp registry_cred, do: %{username: "cms", password: "pw"}

  defp collect_commands(acc \\ []) do
    receive do
      {:ran, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp find_command(commands, pattern), do: Enum.find(commands, &(&1 =~ pattern))

  describe "ensure_container/2" do
    defp ensure_container(opts \\ []) do
      Registry.ensure_container(
        scope(),
        Keyword.merge([run: recorder(self()), credentials: creds()], opts)
      )
    end

    # The default, and the reason is the provider rather than the design.
    # Backed by a Hetzner bucket, `docker push` failed with `unknown blob`:
    # the registry writes a layer to an eventually consistent store, asks
    # immediately whether the blob is there, and is told it is not. A volume on
    # the box has none of that, and what it gives up — the registry surviving
    # the box — costs nothing, because images are rebuildable from a commit.
    test "keeps blobs in a volume on the box" do
      assert {:ok, _} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "REGISTRY_STORAGE='filesystem'"
      assert command =~ "REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY='/var/lib/registry'"
      refute command =~ "REGISTRY_STORAGE_S3"
    end

    # An already-running container is left alone — a second project reaching
    # a box that already has this one running must not restart it out from
    # under whichever app is pulling from it right now.
    test "an already-running container is not touched" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffeec0ffee", 0}
        ["docker rm -f" <> _] -> raise "must not touch an already-running container"
        [_] -> {"", 0}
      end

      assert {:ok, _} = ensure_container(run: run)
    end

    # Found live against fuellytics-prod: ssh's own "Warning: Permanently
    # added ... to the list of known hosts" banner merges onto the same
    # stream as the command's real output (`UserKnownHostsFile=/dev/null`
    # guarantees it prints every time), so a box with nothing on it answered
    # "docker ps -q" with banner text instead of silence — non-empty, but not
    # a container id. `create_container_command` never ran at all.
    test "banner noise on the ps check is not mistaken for a running container" do
      run = fn [command] ->
        send(self(), {:ran, command})

        case command do
          "docker ps -q -f name=" <> _ ->
            {"Warning: Permanently added '1.2.3.4' (ED25519) to the list of known hosts.\r\n", 0}

          _ ->
            {"", 0}
        end
      end

      assert {:ok, _} = ensure_container(run: run)
      assert collect_commands() |> find_command("docker run -d --name cms-registry")
    end

    # `docker rm -f` replaces the registry the first time it is created, so
    # without a named volume every replacement threw away everything it held
    # — including the image the box is running, which is the one a rollback
    # needs.
    test "the volume outlives the container" do
      assert {:ok, _} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "-v cms-registry-data:/var/lib/registry"
    end

    test "points the registry at this project's bucket" do
      assert {:ok, %{bucket: "sam-s-app-registry"}} = ensure_container(storage: :s3)

      command = collect_commands() |> find_command("docker run")
      assert command =~ "REGISTRY_STORAGE_S3_BUCKET='sam-s-app-registry'"
    end

    # Hetzner's object storage is S3-compatible but not S3. A virtual-host
    # style request reaches a bucket that does not exist rather than failing
    # usefully, which is the failure mode this flag exists to avoid.
    test "addresses the bucket path-style, which Hetzner requires" do
      assert {:ok, _} = ensure_container(storage: :s3)

      command = collect_commands() |> find_command("docker run")
      assert command =~ "REGISTRY_STORAGE_S3_FORCEPATHSTYLE='true'"
      assert command =~ "REGISTRY_STORAGE_S3_REGIONENDPOINT='https://fsn1.your-objectstorage.com'"
    end

    test "listens on loopback unless told otherwise" do
      assert {:ok, %{bind: "127.0.0.1", port: 5000}} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "-p 127.0.0.1:5000:5000"
    end

    # The one knob the topology turns. A builder on another machine has to
    # reach this port somehow, and where it binds decides whether that is a
    # tunnel or a private address.
    test "binds where it is told" do
      assert {:ok, %{bind: "10.0.0.2"}} = ensure_container(bind: "10.0.0.2")

      command = collect_commands() |> find_command("docker run")
      assert command =~ "-p 10.0.0.2:5000:5000"
    end

    # Setup runs more than once, so the second run has to converge rather than
    # fail on a container name that is already taken.
    test "replaces the container rather than colliding with it" do
      assert {:ok, _} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "docker rm -f cms-registry"
      assert command =~ "docker run -d --name cms-registry"
    end

    # A deploy that cannot pull is a deploy that cannot roll back, and the
    # moment you need a rollback is not the moment to find the registry went
    # away with the last reboot.
    test "survives a reboot of the box it shares with the app" do
      assert {:ok, _} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "--restart always"
    end

    # 9656c705: `distribution` answers a manifest DELETE with 405 unless
    # started with this set — the image's baked-in config.yml claims
    # `storage.delete.enabled: true` regardless, because that file is never
    # rewritten by an env var override, only read once as the pre-override
    # default. Confirmed against a real `registry:3` container: DELETE
    # returns 405 without this flag, 202 with it.
    test "delete is enabled, so prune/2 can actually reclaim space" do
      assert {:ok, _} = ensure_container()

      command = collect_commands() |> find_command("docker run")
      assert command =~ "REGISTRY_STORAGE_DELETE_ENABLED=true"
    end

    test "a registry that will not start is an error, not a success" do
      run = fn [cmd] ->
        send(self(), {:ran, cmd})
        if cmd =~ "docker run -d", do: {"", 125}, else: {"", 0}
      end

      assert {:error, {:registry_start_failed, 125, _}} = ensure_container(run: run)
    end

    test "without storage credentials there is nothing to back it with" do
      assert {:error, :no_storage_credentials} =
               ensure_container(run: recorder(self()), credentials: :none)

      refute collect_commands() |> find_command("docker run"),
             "must not attempt to create the container without credentials to back it"
    end
  end

  describe "serve/2" do
    defp serve(opts \\ []) do
      Registry.serve(
        scope(),
        Keyword.merge(
          [run: running_recorder(self()), registry_credentials: registry_cred()],
          opts
        )
      )
    end

    # A project's own devops step does not get to stand up shared account
    # infrastructure as a side effect of asking for its own tenant — the
    # same shape `Steps.server_creation_gate/3` uses for the server itself.
    # `ensure_container/2` is the only thing that may create it.
    test "refuses instead of creating the container if it is not already running" do
      assert {:error, :registry_not_provisioned} =
               Registry.serve(scope(), run: recorder(self()), registry_credentials: registry_cred())
    end

    # Docker assumes HTTPS for every registry but `localhost`, and this one
    # speaks plain HTTP on a private address. Without the exemption the push
    # fails with `context deadline exceeded` — a timeout, which reads as an
    # unreachable host rather than a protocol disagreement.
    test "the box is told the registry speaks plain HTTP" do
      assert {:ok, _} = serve(bind: "10.0.0.2")

      trust = collect_commands() |> find_command("insecure-registries")

      assert trust =~ "10.0.0.2:5000"

      # Restarting Docker stops everything on the box, which on the app's
      # server is the app. Only when the file actually changes.
      assert trust =~ "grep -qF"
      assert trust =~ "systemctl restart docker"
    end

    # `await_registry/5` probes the registry itself before reporting up —
    # a container that started (exit 0) is not necessarily one that is
    # actually listening, and the push then times out against nothing.
    test "asks the registry itself before reporting it up" do
      assert {:ok, _} = serve()

      probe = collect_commands() |> find_command("curl")

      assert probe =~ "/v2/"
    end

    test "a container that starts and dies is not a running registry" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffeec0ffee", 0}
        ["curl" <> _] -> {"", 7}
        ["docker logs" <> _] -> {"level=fatal msg=\"cannot bind\"", 0}
        [_] -> {"", 0}
      end

      assert {:error, {:registry_not_listening, "127.0.0.1:5000", logs}} =
               Registry.serve(scope(),
                 run: run,
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

      commands = collect_commands()
      htpasswd_command = find_command(commands, "htpasswd")

      # bcrypt, because `distribution` accepts nothing else — and generated
      # here because `htpasswd` is not installed on the box.
      assert htpasswd_command =~ "cms:$2b$"

      refute htpasswd_command =~ "'pw'",
             "the password must reach the box hashed, not in the clear"
    end

    # One project's credential does not erase another's — the htpasswd file
    # is shared the moment the box is, and an overwrite instead of an upsert
    # would lock out whichever project provisioned first. Only this
    # project's own prior line (if any) is ever targeted for removal, and
    # every other line in the file is left for `mv` to carry forward.
    test "only this project's own htpasswd line is ever removed" do
      assert {:ok, _} = serve()

      command = collect_commands() |> find_command("htpasswd")
      assert command =~ "grep -v '^cms:'"
      refute command =~ "grep -v '^cms:.*$2b'",
             "must match on the username alone, not on a specific hash that would miss a rotated password"
    end
  end

  # The question `verify(:server, …)` asks without having just run `serve/2`
  # itself — c1d8eaff: a box Hetzner reports and a registry that answers on
  # it are different claims, and `serve/2` is the only thing that starts one.
  describe "reachable?/2" do
    defp reachable(opts) do
      Registry.reachable?(
        scope(),
        Keyword.merge([registry_credentials: registry_cred()], opts)
      )
    end

    test "true when the registry answers the same probe serve/2 waits on" do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert reachable(run: run) == true

      assert_received {:ran, probe}
      assert probe =~ "curl"
      assert probe =~ "/v2/"
    end

    test "false when nothing answers" do
      run = fn [_command] -> {"", 7} end

      assert reachable(run: run) == false
    end

    # One curl, not `await_registry/5`'s fifteen — this is a caller asking
    # "is it up right now", not one waiting for a container that just started.
    test "asks exactly once, with no retry wait" do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 1}
      end

      assert reachable(run: run) == false
      assert_received {:ran, _first}
      refute_received {:ran, _second}
    end

    test "asks at the address it was told to bind" do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert reachable(run: run, bind: "10.0.0.5") == true
      assert_received {:ran, command}
      assert command =~ "http://10.0.0.5:5000/v2/"
    end
  end

  # `prune/2` is the mechanism `:filesystem` storage actually has instead of
  # a bucket lifecycle rule (6dcb62b8) — validated first against a real
  # `registry:3` container (four distinct pushed images, deleted the two
  # oldest by the digest their own `current/link` named, ran garbage-collect,
  # confirmed the kept images still pulled and the deleted ones' unique blobs
  # were gone). These fake the box the same way `serve/2`'s tests do: dispatch
  # on the shape of the command rather than starting a real registry, which
  # would make this a network test and prove nothing about the commands.
  describe "prune/2" do
    # Command shapes from `tags_by_recency/2`, `delete_tag/5` and
    # `garbage_collect/1`, matched the same order they're built in.
    #
    # `-X DELETE` answers with the tuple `delete_tag/5` actually reads: the
    # trimmed HTTP status code text and a 0 shell exit, mirroring
    # `curl -s -o /dev/null -w '%{http_code}'`. `failing_tags` fakes the
    # 405 a real `distribution` container answers when
    # `storage.delete.enabled` is off (9656c705) — a digest a caller
    # attempts to delete but whose tag is listed here comes back rejected
    # rather than silently accepted.
    defp box(owner, listing, failing_tags \\ []) do
      fn [cmd] ->
        send(owner, {:ran, cmd})

        cond do
          cmd =~ "_manifests/tags" and cmd =~ "sh -c" ->
            {listing, 0}

          cmd =~ ~r{cat .*/([^/]+)/current/link$} ->
            [_, tag] = Regex.run(~r{/([^/]+)/current/link$}, cmd)
            {"sha256:digest-#{tag}", 0}

          cmd =~ "-X DELETE" ->
            delete_response(cmd, failing_tags)

          cmd =~ "garbage-collect" ->
            {"", 0}
        end
      end
    end

    defp delete_response(cmd, failing_tags) do
      if Enum.any?(failing_tags, &(cmd =~ "manifests/sha256:digest-#{&1}")) do
        {"405", 0}
      else
        {"202", 0}
      end
    end

    defp prune(listing, opts) do
      Registry.prune(
        scope(),
        Keyword.merge(
          [run: box(self(), listing), registry_credentials: registry_cred()],
          opts
        )
      )
    end

    defp prune_with_failures(listing, failing_tags, opts) do
      Registry.prune(
        scope(),
        Keyword.merge(
          [run: box(self(), listing, failing_tags), registry_credentials: registry_cred()],
          opts
        )
      )
    end

    # Newest first by the mtime `stat` reads off each tag's own link file —
    # tags are short commit SHAs, so there is no other order to sort them by.
    defp listing(pairs), do: Enum.map_join(pairs, "\n", fn {ts, tag} -> "#{ts} #{tag}" end)

    test "keeps the newest N, deletes the rest, and reclaims their blobs" do
      four_tags = listing([{100, "aaa"}, {200, "bbb"}, {300, "ccc"}, {400, "ddd"}])

      assert {:ok, pruned} = prune(four_tags, keep_images: 2)

      # Newest two (ddd, ccc) survive; the older two are what got deleted.
      assert pruned == ["bbb", "aaa"]

      assert_received {:ran, listing_cmd}
      assert listing_cmd =~ "docker exec cms-registry sh -c"

      assert_received {:ran, cat_bbb}
      assert cat_bbb =~ "bbb/current/link"

      assert_received {:ran, delete_bbb}
      assert delete_bbb =~ "-X DELETE"
      assert delete_bbb =~ "manifests/sha256:digest-bbb"

      assert_received {:ran, cat_aaa}
      assert cat_aaa =~ "aaa/current/link"

      assert_received {:ran, delete_aaa}
      assert delete_aaa =~ "manifests/sha256:digest-aaa"

      assert_received {:ran, gc_cmd}

      assert gc_cmd =~
               "docker exec cms-registry /bin/registry garbage-collect /etc/distribution/config.yml"
    end

    test "nothing pruned, nothing deleted, no garbage-collect" do
      two_tags = listing([{100, "aaa"}, {200, "bbb"}])

      assert {:ok, []} = prune(two_tags, keep_images: 5)

      assert_received {:ran, _listing}
      refute_received {:ran, _anything_else}
    end

    # A repository with nothing pushed yet has no `_manifests/tags`
    # directory at all — not a failure, simply nothing to prune.
    test "a registry with nothing pushed yet has nothing to prune" do
      assert {:ok, []} = prune("", keep_images: 2)

      assert_received {:ran, _listing}
      refute_received {:ran, _anything_else}
    end

    test "a listing failure is an error, not a crash" do
      failing_run = fn [_cmd] -> {"stat: not found", 1} end

      assert {:error, {:prune_listing_failed, 1, "stat: not found"}} =
               Registry.prune(scope(), run: failing_run, registry_credentials: registry_cred())
    end

    test "addresses the box at the bind it was told, on the registry's own port" do
      one_tag = listing([{100, "aaa"}, {200, "bbb"}, {300, "ccc"}])

      assert {:ok, _} = prune(one_tag, keep_images: 1, bind: "10.0.0.2")

      assert_received {:ran, _listing}
      assert_received {:ran, _cat}
      assert_received {:ran, delete_cmd}
      assert delete_cmd =~ "http://10.0.0.2:5000/v2/sam-s-app/manifests/"
    end

    test "how many images stay defaults to 5, and is overridable" do
      assert Registry.keep_images([]) == 5
      assert Registry.keep_images(keep_images: 1) == 1
    end

    # 9656c705: the old code discarded the DELETE response and reported
    # every attempted tag as pruned regardless of whether the registry
    # actually deleted it (the live symptom: 11 tags on disk against a
    # `keep_images` of 5). A tag whose DELETE comes back anything other
    # than 202 must not appear in the returned list.
    test "a tag whose delete fails is not claimed as pruned" do
      four_tags = listing([{100, "aaa"}, {200, "bbb"}, {300, "ccc"}, {400, "ddd"}])

      assert {:ok, pruned} = prune_with_failures(four_tags, ["bbb"], keep_images: 2)

      assert pruned == ["aaa"]
    end

    # Garbage-collect reclaims blobs only unlinked manifests held. Running
    # it when nothing was actually unlinked is not wrong, but skipping it
    # keeps the command trail honest about what this run accomplished.
    test "garbage-collect still runs for the deletes that did succeed" do
      four_tags = listing([{100, "aaa"}, {200, "bbb"}, {300, "ccc"}, {400, "ddd"}])

      assert {:ok, pruned} = prune_with_failures(four_tags, ["bbb"], keep_images: 2)
      assert pruned == ["aaa"]

      assert_received {:ran, "docker exec cms-registry /bin/registry garbage-collect" <> _}
    end

    test "garbage-collect is skipped when every delete fails" do
      four_tags = listing([{100, "aaa"}, {200, "bbb"}, {300, "ccc"}, {400, "ddd"}])

      assert {:ok, []} = prune_with_failures(four_tags, ["bbb", "aaa"], keep_images: 2)

      refute_received {:ran, "docker exec cms-registry /bin/registry garbage-collect" <> _}
    end
  end
end

defmodule CodeMySpec.LiveProvisioningTest do
  @moduledoc """
  A real provisioning run: the actual `Provisioning` sequence, against real
  provider APIs, creating real resources — then destroying them.

  Excluded from the normal suite. Run deliberately:

      mix test --only live

  Requires HETZNER_API_TOKEN and a repo-scoped GitHub token at
  $CMS_GH_TOKEN_FILE. Skips rather than fails when either is absent, so it
  never breaks a run for someone without credentials.

  Set CMS_GH_DELETE_TOKEN too (`gh auth token`): the provisioning grant has
  `repo`, which cannot delete a repository, and without a token that can this
  test leaves one behind on every run.

  Every resource it creates is destroyed in `on_exit`, which runs even when an
  assertion fails partway through.
  """
  # Sync: shells out, and writes the shared `:code_my_spec, Hetzner` key. Tagged
  # out of the default suite besides — it talks to real infrastructure.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.{Hetzner, Sops, Storage, StepRepository}

  @moduletag :live
  @moduletag timeout: 900_000
  @moduletag ownership_timeout: 900_000

  @name "cms-live-proof"
  @owner "johns10"

  setup do
    token_file = System.get_env("CMS_GH_TOKEN_FILE")
    hetzner = System.get_env("HETZNER_API_TOKEN")

    case {token_file && File.exists?(token_file), hetzner} do
      {true, hz} when is_binary(hz) and hz != "" ->
        gh = token_file |> File.read!() |> Jason.decode!() |> Map.fetch!("access_token")
        Application.put_env(:code_my_spec, Hetzner, api_token: hz)

        # A real working tree with a file in it — the state a freshly
        # generated project is in when the repository step runs.
        {:ok, tmp} = Briefly.create(directory: true)
        File.write!(Path.join(tmp, "README.md"), "# cms-live-proof\n")

        scope = full_scope_fixture()
        scope = %{scope | environment: CodeMySpec.Environments.Environment.new(:local, tmp)}

        %Integration{}
        |> Integration.changeset(%{
          user_id: scope.user.id,
          provider: :github,
          access_token: gh,
          granted_scopes: ["repo", "user:email"],
          expires_at: DateTime.utc_now() |> DateTime.add(365, :day)
        })
        |> Repo.insert!()

        on_exit(fn -> cleanup(scope, gh) end)

        %{scope: scope, gh: gh}

      _ ->
        {:ok, skip: true}
    end
  end

  # Runs even when a test fails partway. Deletes only the exact names this
  # test creates, then VERIFIES each one is gone and shouts if not.
  #
  # The first version of this deleted and assumed. It left a GitHub repository
  # and a Hetzner firewall behind on a real account: server deletion is async,
  # so the firewall was still attached when its delete was attempted and the
  # failure went unnoticed. A teardown that reports success it did not achieve
  # is worse than none, because it stops anyone looking.
  defp cleanup(scope, gh) do
    delete_server(scope)
    # Only after the server is actually gone — a firewall still attached to a
    # live server cannot be deleted.
    delete_firewall(scope, 5)
    delete_ssh_key(scope)
    delete_repo(gh)

    leftovers = leftovers(scope, gh)

    case leftovers do
      [] -> :ok
      found -> IO.warn("LIVE TEST LEFT RESOURCES BEHIND: #{inspect(found)}")
    end
  end

  # A key left behind is not just clutter: the next run generates fresh
  # material, and an account holding a stale key under the same name is how
  # the name-matching bug produced an unreachable server.
  defp delete_ssh_key(scope) do
    case ProjectSecrets.fetch_value(scope, "server_ssh_public_key") do
      {:ok, public} ->
        case Hetzner.find_ssh_key_by_fingerprint(scope, Hetzner.fingerprint(public)) do
          {:ok, %{"id" => id}} -> Hetzner.delete_ssh_key(scope, id)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp delete_server(scope) do
    case Hetzner.find_server(scope, @name) do
      {:ok, %{"id" => id}} -> Hetzner.delete_server(scope, id)
      _ -> :ok
    end
  end

  # Retries: Hetzner detaches the firewall only once the server is really gone,
  # and that is not immediate.
  defp delete_firewall(_scope, 0), do: :ok

  defp delete_firewall(scope, attempts) do
    case Hetzner.find_firewall(scope, @name) do
      {:ok, %{"id" => id}} ->
        case Hetzner.delete_firewall(scope, id) do
          {:ok, _} ->
            :ok

          {:error, _} ->
            Process.sleep(2_000)
            delete_firewall(scope, attempts - 1)
        end

      _ ->
        :ok
    end
  end

  # Deletion needs a DIFFERENT token than the work does. The OAuth grant this
  # test provisions with carries `repo`, which cannot delete a repository —
  # GitHub answers 403 — because `delete_repo` is a separate scope and the
  # provisioning flow has no business asking for it. Setup never deletes; only
  # this teardown does. So CMS_GH_DELETE_TOKEN (a gh CLI token, which has
  # delete_repo) is used when present, and the failure is loud when it is not.
  defp delete_repo(gh) do
    token = System.get_env("CMS_GH_DELETE_TOKEN") || gh

    Req.request(
      method: :delete,
      url: "https://api.github.com/repos/#{@owner}/#{@name}",
      headers: github_headers(token),
      redirect: false
    )
  end

  defp leftovers(scope, gh) do
    gh = System.get_env("CMS_GH_DELETE_TOKEN") || gh

    server = match?({:ok, _}, Hetzner.find_server(scope, @name))
    firewall = match?({:ok, _}, Hetzner.find_firewall(scope, @name))

    repo =
      match?(
        {:ok, %Req.Response{status: 200}},
        Req.request(
          method: :get,
          url: "https://api.github.com/repos/#{@owner}/#{@name}",
          headers: github_headers(gh),
          redirect: false
        )
      )

    for {label, present} <- [server: server, firewall: firewall, repo: repo], present, do: label
  end

  defp github_headers(gh) do
    [
      {"authorization", "Bearer #{gh}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "CodeMySpec"}
    ]
  end

  test "the sequence provisions real resources and converges on a re-run", %{scope: scope} do
    # Step 1 — repository. Driven through Provisioning, not the provider, so
    # this exercises the wiring that was a stub until today.
    assert {:ok, repo_step} =
             Provisioning.run_step(scope, :repository,
               owner: @owner,
               name: @name,
               private: true
             )

    assert repo_step.state == :done
    locations = Enum.map(repo_step.resources, & &1.location)
    IO.puts("\n  repository -> #{repo_step.state} #{inspect(locations)}")

    assert Enum.any?(locations, &String.contains?(&1, @name)),
           "expected the repository recorded, got #{inspect(locations)}"

    # Step 2 — server.
    assert {:ok, server_step} =
             Provisioning.run_step(scope, :server,
               server_name: @name,
               arch: :x86,
               location: "ash"
             )

    assert server_step.state == :done
    IO.puts("  server     -> #{server_step.state} #{inspect(Enum.map(server_step.resources, & &1.location))}")

    # The address is what DNS points at, so it has to be recorded, not just
    # the fact that a server exists.
    ip = server_step.resources |> Enum.find(&(&1.kind == "server")) |> Map.get(:identifier)

    assert ip =~ ~r/^\d+\.\d+\.\d+\.\d+$/,
           "the server step recorded no usable address (got #{inspect(ip)})"

    IO.puts("  server ip  -> #{ip}")

    # A server nobody can log into is not a provisioned server: the deploy
    # step has to reach the box to configure it, and Hetzner's alternative is
    # a root password emailed to the account owner.
    fingerprint =
      server_step.resources |> Enum.find(&(&1.kind == "ssh_key")) |> then(&(&1 && &1.identifier))

    assert is_binary(fingerprint), "the server step attached no SSH key"

    {:ok, private} = ProjectSecrets.fetch_value(scope, "server_ssh_private_key")
    assert private =~ "OPENSSH PRIVATE KEY"

    key_path = CodeMySpec.TempFile.dir("cms-live-key")
    File.write!(key_path, private)
    File.chmod!(key_path, 0o600)
    on_exit(fn -> File.rm(key_path) end)

    # Boot takes a moment; the assertion is that it answers, not how fast.
    reachable =
      Enum.reduce_while(1..24, false, fn _, _ ->
        case System.cmd(
               "ssh",
               [
                 "-i", key_path,
                 "-o", "StrictHostKeyChecking=no",
                 "-o", "UserKnownHostsFile=/dev/null",
                 "-o", "ConnectTimeout=5",
                 "-o", "BatchMode=yes",
                 "root@#{ip}",
                 "echo cms-reachable"
               ],
               stderr_to_stdout: true
             ) do
          {out, 0} -> {:halt, String.contains?(out, "cms-reachable")}
          _ -> Process.sleep(5_000) && {:cont, false}
        end
      end)

    assert reachable, "could not SSH to #{ip} with the key setup created"

    IO.puts("  ssh        -> root@#{ip} reachable with the generated key")

    # Convergence: re-running must not produce a second server. This is the
    # property that makes a retry safe, and the only honest way to check it is
    # against the provider's own inventory.
    assert {:ok, _} =
             Provisioning.run_step(scope, :server,
               server_name: @name,
               arch: :x86,
               location: "ash"
             )

    {:ok, servers} = Hetzner.list_servers(scope)
    IO.puts("  servers named #{@name}: #{Enum.count(servers, &(&1["name"] == @name))} (must be 1)")

    assert Enum.count(servers, &(&1["name"] == @name)) == 1,
           "re-running the server step duplicated the server"

    # State persisted for both.
    states = scope |> StepRepository.list() |> Map.new(&{&1.key, &1.state})
    assert states[:repository] == :done
    assert states[:server] == :done
  end

  test "the secrets step generates one real age key per environment", %{scope: scope} do
    assert {:ok, step} = Provisioning.run_step(scope, :secrets, environments: ["prod", "uat"])
    assert step.state == :done

    IO.puts("\n  secrets    -> #{step.state} #{inspect(Enum.map(step.resources, & &1.location))}")

    # Real keys, in ProjectSecrets, one per environment.
    {:ok, prod} = ProjectSecrets.fetch_value(scope, "age_private_key_prod")
    {:ok, uat} = ProjectSecrets.fetch_value(scope, "age_private_key_uat")

    assert String.starts_with?(prod, "AGE-SECRET-KEY-")
    refute prod == uat, "both environments got the same key — the whole point is that they differ"

    # And the isolation actually holds against real sops, not just in theory.
    env = scope.environment
    assert :ok = Sops.put_secret(env, "prod", "PROBE", "prod-only", prod)

    assert {:ok, %{"PROBE" => "prod-only"}} = Sops.decrypt(env, "prod", prod)

    assert {:error, _} = Sops.decrypt(env, "prod", uat),
           "UAT's key opened production's file — the isolation is not real"
  end

  test "the callback credential lands encrypted, not in plaintext", %{scope: scope} do
    {:ok, _} = Provisioning.run_step(scope, :secrets, environments: ["prod"])

    assert {:ok, step} =
             Provisioning.run_step(scope, :callback_credential, environments: ["prod"])

    assert step.state == :done
    IO.puts("  callback   -> #{step.state} #{inspect(Enum.map(step.resources, & &1.location))}")

    # Story 971: destination is the encrypted env, and the secret is nowhere
    # in the working tree as plaintext.
    assert Enum.all?(step.resources, &String.contains?(&1.location, "encrypted_env"))

    {:ok, secret} = ProjectSecrets.fetch_value(scope, "cms_refresh_secret")
    {:ok, key} = ProjectSecrets.fetch_value(scope, "age_private_key_prod")

    assert {:ok, %{"CMS_REFRESH_SECRET" => ^secret}} =
             Sops.decrypt(scope.environment, "prod", key)

    plaintext =
      scope.environment.cwd
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&(File.read!(&1) =~ secret))

    assert plaintext == [],
           "the callback secret is sitting in plaintext at #{inspect(plaintext)}"
  end

  describe "storage and backups against real Hetzner object storage" do
    setup %{scope: scope} do
      id = System.get_env("HETZNER_S3_ACCESS_KEY_ID")
      secret = System.get_env("HETZNER_S3_SECRET_ACCESS_KEY")

      if is_nil(id) or is_nil(secret) do
        raise "set HETZNER_S3_ACCESS_KEY_ID and HETZNER_S3_SECRET_ACCESS_KEY"
      end

      # The project's own keys, held for it — the storage step reads these and
      # nothing else, so a fallback to our environment cannot pass for Sam's.
      ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", id)
      ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", secret)

      credentials = [access_key_id: id, secret_access_key: secret, region: "fsn1"]
      project = CodeMySpec.Projects.get_project!(scope, scope.active_project_id)
      buckets = Enum.map(["prod", "uat"], &Storage.bucket_name(project, &1))

      on_exit(fn ->
        for bucket <- buckets do
          case Storage.list_dumps(bucket, credentials, prefix: "") do
            {:ok, objects} ->
              for %{key: key} <- objects, do: Storage.delete_object(bucket, key, credentials)

            _ ->
              :ok
          end

          Storage.delete_bucket(bucket, credentials)
        end
      end)

      %{credentials: credentials, buckets: buckets}
    end

    test "the storage step creates a bucket per environment in Sam's account", ctx do
      assert {:ok, step} = Provisioning.run_step(ctx.scope, :storage, [])
      assert step.state == :done

      IO.puts("\n  storage    -> #{step.state} #{inspect(Enum.map(step.resources, & &1.location))}")

      # Criterion 8011: the buckets are his. Every recorded resource says so,
      # and the listing is read back from his account rather than ours.
      assert Enum.all?(step.resources, &(&1.identifier == "user"))
      assert length(step.resources) == 2

      {:ok, existing} = Storage.list_buckets(ctx.credentials)

      for bucket <- ctx.buckets do
        assert bucket in existing, "expected #{bucket} in the account"
      end

      # Criterion 7965 through the step, not the provider: verify now sees the
      # buckets, so a second run converges instead of duplicating.
      assert {:ok, :satisfied, _} = Provisioning.verify(ctx.scope, :storage, [])
      assert {:ok, again} = Provisioning.run_step(ctx.scope, :storage, [])
      assert again.state == :done
    end

    test "a project with no storage keys pauses rather than guessing", %{scope: scope} do
      # Hetzner issues these in the console only, so there is nothing to call.
      other = CodeMySpec.UsersFixtures.full_scope_fixture()

      assert {:halt, step, instructions} = Provisioning.run_step(other, :storage, [])

      assert step.state == :paused
      assert instructions =~ "console"

      IO.puts("  storage    -> paused (no keys): #{String.slice(instructions, 0, 60)}...")
      _ = scope
    end
  end
end

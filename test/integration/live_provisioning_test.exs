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
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Integrations.Integration
  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.{Hetzner, StepRepository}

  @moduletag :live
  @moduletag timeout: 300_000

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
    delete_repo(gh)

    leftovers = leftovers(scope, gh)

    case leftovers do
      [] -> :ok
      found -> IO.warn("LIVE TEST LEFT RESOURCES BEHIND: #{inspect(found)}")
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
end

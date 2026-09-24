defmodule CmsHarness.ServedRootsTest do
  use ExUnit.Case, async: false

  alias CmsHarness.{HarnessConfig, Projects, ServedRoots}

  setup do
    dir = Path.join(System.tmp_dir!(), "served_roots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    keys = [
      :harness_served_roots_dir,
      :harness_server_url_override,
      :harness_token,
      :harness_deploy_key
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:code_my_spec, &1)})
    variables = ~w(CMS_PROJECT_DIR CMS_PROJECT_ID CMS_TOKEN CMS_DEPLOY_KEY)
    environment = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &System.delete_env/1)
    Enum.each(keys, &Application.delete_env(:code_my_spec, &1))
    Application.put_env(:code_my_spec, :harness_served_roots_dir, Path.join(dir, "hints"))
    Application.put_env(:code_my_spec, :harness_server_url_override, "http://127.0.0.1:1")

    # These are the actual registry and project subtree used by the boot seam.
    # No endpoint or server application is started; the test URL cannot reach
    # any of the developer's servers and the fixture credential is invented.
    if is_nil(Process.whereis(CmsHarness.Registry)) do
      start_supervised!({Registry, keys: :unique, name: CmsHarness.Registry})
    end

    if is_nil(Process.whereis(CmsHarness.ProjectSupervisor)) do
      start_supervised!(
        {DynamicSupervisor, name: CmsHarness.ProjectSupervisor, strategy: :one_for_one}
      )
    end

    on_exit(fn ->
      for root <- Projects.list(), String.starts_with?(root, dir) do
        Projects.stop_serving(root)
      end

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:code_my_spec, key)
        {key, value} -> Application.put_env(:code_my_spec, key, value)
      end)

      Enum.each(environment, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "boot restores an agent-only root after the project tree was lost", %{dir: dir} do
    root = copy(dir, "agent-only")
    assert {:ok, _} = Projects.ensure_started(root)
    [{pid, _}] = Registry.lookup(CmsHarness.Registry, {:project, root})
    # A process restart, not offboarding: terminating the child bypasses the
    # deliberate stop_serving operation, just as an application shutdown does.
    assert :ok = DynamicSupervisor.terminate_child(CmsHarness.ProjectSupervisor, pid)
    refute root in Projects.list()
    rewrite(root, "deploy_key", "rotated-key")
    [hint] = Path.wildcard(Path.join(dir, "hints/**/*.json"))
    File.write!(Path.join(Path.dirname(hint), "corrupt.json"), "invalid JSON")

    assert :ok = Projects.start_configured()
    assert root in Projects.list()
    assert {:ok, "rotated-key", :working_copy_key} = CmsHarness.Credentials.for_working_copy(root)

    assert :ok = Projects.stop_serving(root)
    assert :ok = Projects.start_configured()
    refute root in Projects.list()
  end

  test "boot ignores missing paths, changed identities, other servers and removed credentials", %{
    dir: dir
  } do
    roots =
      for name <- ~w(missing identity server credential) do
        root = copy(dir, name)
        assert {:ok, _} = Projects.ensure_started(root)
        [{pid, _}] = Registry.lookup(CmsHarness.Registry, {:project, root})
        DynamicSupervisor.terminate_child(CmsHarness.ProjectSupervisor, pid)
        root
      end

    [missing, identity, server, credential] = roots
    File.rm_rf!(missing)
    rewrite(identity, "working_copy_id", "re-onboarded")
    rewrite(server, "server_url", "https://another-server.invalid")
    rewrite(credential, "deploy_key", nil)

    assert :ok = Projects.start_configured()
    assert Enum.all?(roots, &(&1 not in Projects.list()))
  end

  test "hints contain no credentials and are isolated by server", %{dir: dir} do
    root = copy(dir, "one")
    assert {:ok, _} = Projects.ensure_started(root)
    [path] = Path.wildcard(Path.join(dir, "hints/**/*.json"))
    refute File.read!(path) =~ "fixture-key"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert ServedRoots.list() == [root]

    Application.put_env(
      :code_my_spec,
      :harness_server_url_override,
      "https://another-server.invalid"
    )

    assert ServedRoots.list() == []
  end

  defp copy(dir, name) do
    root = Path.join(dir, name)
    File.mkdir_p!(root)

    :ok =
      HarnessConfig.write(root, %{
        working_copy_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        deploy_key: "fixture-key",
        server_url: "http://127.0.0.1:1"
      })

    root
  end

  defp rewrite(root, key, value) do
    path = HarnessConfig.path(root)
    contents = path |> File.read!() |> Jason.decode!() |> Map.put(key, value)
    File.write!(path, Jason.encode!(contents))
  end
end

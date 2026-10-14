defmodule CodeMySpecDesktop.BootstrapTest do
  use ExUnit.Case, async: false

  alias CodeMySpecDesktop.Application.{Bootstrap, Shell}

  setup do
    root = Path.join(System.tmp_dir!(), "desktop-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", root)

    on_exit(fn ->
      restore_path(previous_path)
      File.rm_rf!(root)
    end)

    parent = self()

    view = fn url ->
      {Task,
       fn ->
         send(parent, {:window_opened, url})

         receive do
           :close -> :ok
         end
       end}
    end

    shell =
      start_supervised!(
        {Shell,
         view: view,
         app_url: "http://127.0.0.1:4000/app",
         setup_opts: [directory: Path.join(root, "setup")],
         runtime: CodeMySpecTest.UnavailableDesktopRuntime}
      )

    assert_receive {:window_opened, url}
    %{root: root, shell: shell, url: url}
  end

  test "the window serves setup before checks and without starting the runtime", ctx do
    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "Set up this machine"
    assert response.body =~ "setup-agent-unavailable"
    assert response.body =~ "Check prerequisites"
    refute File.exists?(Path.join(ctx.root, "setup"))
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    assert Process.alive?(ctx.shell)
  end

  test "missing Postgres produces persisted guidance while the window remains available", ctx do
    assert Req.post!(ctx.url <> "/check", redirect: false).status == 303
    status = await_settled(100)
    postgres = Enum.find(status.snapshot["steps"], &(&1["key"] == "postgres"))
    assert postgres["state"] == "errored"
    assert [%{"exit_status" => nil}] = postgres["commands"]
    assert File.regular?(status.snapshot["results_path"])
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 409

    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "Install PostgreSQL"
    assert response.body =~ "Install pgvector"
    assert response.body =~ "Manual setup is available"
    assert Process.alive?(ctx.shell)
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
  end

  test "a database startup failure leaves setup available for retry", ctx do
    Enum.each(
      [
        {"psql", "psql (PostgreSQL) 16.4\nvector|0.8.0"},
        {"mise", "erlang 27.2\nelixir 1.18.1"},
        {"erl", "27"},
        {"elixir", "Elixir 1.18.1"},
        {"cms", "cms 2.0.0"},
        {"vibium", "Vibium 1.0.0"}
      ],
      fn {name, output} ->
        path = Path.join(ctx.root, name)
        File.write!(path, "#!/bin/sh\nprintf '%s\\n' '#{output}'\n")
        File.chmod!(path, 0o700)
      end
    )

    assert Req.post!(ctx.url <> "/check", redirect: false).status == 303
    checked = await_settled(100)
    assert CmsHarness.Setup.prerequisites_passed?(checked.snapshot)
    recorded = File.read!(checked.snapshot["results_path"])
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    failed = await_settled(100)
    assert failed.error =~ "database_unavailable"
    assert Process.alive?(ctx.shell)
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "database_unavailable"
    assert File.read!(checked.snapshot["results_path"]) == recorded
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    assert await_settled(100).error =~ "database_unavailable"
  end

  test "database startup failure leaves the setup window available", ctx do
    Enum.each(
      [
        {"psql", "psql (PostgreSQL) 16.4\nvector|0.8.0"},
        {"mise", "erlang 27.2\nelixir 1.18.1"},
        {"erl", "27"},
        {"elixir", "Elixir 1.18.1"},
        {"cms", "cms 2.0.0"},
        {"vibium", "Vibium 1.0.0"}
      ],
      fn {name, output} ->
        executable = Path.join(ctx.root, name)
        File.write!(executable, "#!/bin/sh\nprintf '%s\\n' '#{output}'\n")
        File.chmod!(executable, 0o700)
      end
    )

    assert Req.post!(ctx.url <> "/check", redirect: false).status == 303
    checked = await_settled(100)
    assert CmsHarness.Setup.prerequisites_passed?(checked.snapshot)
    recorded = File.read!(checked.snapshot["results_path"])
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    failed = await_settled(100)
    assert failed.error =~ "database_unavailable"

    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "database_unavailable"
    assert response.body =~ "Check prerequisites"
    assert Process.alive?(ctx.shell)
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    assert File.read!(checked.snapshot["results_path"]) == recorded
  end

  test "unknown launch tokens and cross-origin actions cannot run checks", ctx do
    uri = URI.parse(ctx.url)
    unknown = URI.to_string(%{uri | path: "/setup/unknown"})
    assert Req.get!(unknown).status == 404

    response =
      Req.post!(ctx.url <> "/check",
        headers: [{"origin", "https://other.invalid"}],
        redirect: false
      )

    assert response.status == 403
    assert Bootstrap.status(Bootstrap).snapshot == nil
    refute File.exists?(Path.join(ctx.root, "setup"))
  end

  defp await_settled(attempts) do
    await_status(Bootstrap.status(Bootstrap), attempts)
  end

  defp await_status(%{phase: :setup} = status, _attempts), do: status
  defp await_status(status, 0), do: flunk("Bootstrap did not settle: #{inspect(status)}")

  defp await_status(_status, attempts) do
    Process.sleep(20)
    await_settled(attempts - 1)
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end

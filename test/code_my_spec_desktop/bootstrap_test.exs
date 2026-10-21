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
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:code_my_spec_desktop, :bootstrap, :settled],
        &__MODULE__.handle_bootstrap_settled/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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
    assert response.body =~ ~s(data-test="check-prerequisites")
    refute File.exists?(Path.join(ctx.root, "setup"))
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    assert Process.alive?(ctx.shell)
  end

  test "missing Postgres produces persisted guidance while the window remains available", ctx do
    assert Req.post!(ctx.url <> "/check", redirect: false).status == 303
    status = await_settled()
    postgres = Enum.find(status.snapshot["steps"], &(&1["key"] == "postgres"))
    assert postgres["state"] == "errored"
    assert [%{"exit_status" => nil}] = postgres["commands"]
    assert File.regular?(status.snapshot["results_path"])
    # Start is offered whatever the checklist says: the app needs none of it.
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    await_settled()

    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "Install PostgreSQL"
    assert response.body =~ "Install pgvector"
    assert response.body =~ ~s(data-test="setup-agent-unavailable")
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
    checked = await_settled()
    assert CmsHarness.Setup.prerequisites_passed?(checked.snapshot)
    recorded = File.read!(checked.snapshot["results_path"])
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    failed = await_settled()
    assert failed.error =~ "database_unavailable"
    assert Process.alive?(ctx.shell)
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "database_unavailable"
    assert File.read!(checked.snapshot["results_path"]) == recorded
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    assert await_settled().error =~ "database_unavailable"
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
    checked = await_settled()
    assert CmsHarness.Setup.prerequisites_passed?(checked.snapshot)
    recorded = File.read!(checked.snapshot["results_path"])
    assert Req.post!(ctx.url <> "/continue", redirect: false).status == 303
    failed = await_settled()
    assert failed.error =~ "database_unavailable"

    response = Req.get!(ctx.url)
    assert response.status == 200
    assert response.body =~ "database_unavailable"
    assert response.body =~ ~s(data-test="check-prerequisites")
    assert Process.alive?(ctx.shell)
    assert DynamicSupervisor.which_children(CodeMySpecDesktop.RuntimeSupervisor) == []
    assert File.read!(checked.snapshot["results_path"]) == recorded
  end

  test "setup forms preserve and accept the listener origin", ctx do
    page = Req.get!(ctx.url)
    assert Req.Response.get_header(page, "referrer-policy") == ["same-origin"]
    uri = URI.parse(ctx.url)
    origin = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})

    response = Req.post!(ctx.url <> "/check", headers: [{"origin", origin}], redirect: false)
    assert response.status == 303
    status = await_settled()
    assert File.regular?(status.snapshot["results_path"])

    assert Req.post!(ctx.url <> "/continue", headers: [{"origin", origin}], redirect: false).status ==
             303
  end

  test "opaque origins cannot run setup checks", ctx do
    response = Req.post!(ctx.url <> "/check", headers: [{"origin", "null"}], redirect: false)
    assert response.status == 403
    assert Bootstrap.status(Bootstrap).snapshot == nil
    refute File.exists?(Path.join(ctx.root, "setup"))
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

  test "authorization retries require the launch token and same origin", ctx do
    uri = URI.parse(ctx.url)
    unknown = URI.to_string(%{uri | path: "/setup/unknown/authorize"})
    assert Req.post!(unknown, redirect: false).status == 404

    response =
      Req.post!(ctx.url <> "/authorize",
        headers: [{"origin", "https://other.invalid"}],
        redirect: false
      )

    assert response.status == 403
  end

  def handle_bootstrap_settled(_event, _measurements, metadata, recipient) do
    send(recipient, {:bootstrap_settled, metadata.bootstrap, metadata.status})
  end

  defp await_settled do
    bootstrap = Process.whereis(Bootstrap)

    # Completion may arrive before the HTTP response; the mailbox retains it.
    # ExUnit's test timeout still bounds a missing completion event.
    receive do
      {:bootstrap_settled, ^bootstrap, status} ->
        assert status.phase == :setup
        assert Bootstrap.status(Bootstrap) == status
        status
    end
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end

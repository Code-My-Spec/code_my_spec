defmodule CodeMySpec.McpServers.Devops.Tools.AdoptRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.GitHub
  alias CodeMySpec.McpServers.Devops.Tools.AdoptRepository
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.RunLock
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    {:ok, working_dir} = Briefly.create(directory: true)
    File.write!(Path.join(working_dir, "README.md"), "# market_my_spec\n")

    {:ok, bare_dir} = Briefly.create(directory: true)
    {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", bare_dir])

    scope = full_scope_fixture()
    _ = github_integration_fixture(scope.user)
    scope = %{scope | environment: Environment.new(:local, working_dir)}

    %{scope: scope, project: scope.active_project, bare_dir: bare_dir}
  end

  defp stub_github(fun), do: Req.Test.stub(GitHub, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "execute/2" do
    # The whole point: a real repo named "market_my_spec" (underscores) does
    # not exactly match what setup would derive from a project name like
    # "Market My Spec" (dashes) — a plain run_devops_setup would miss this
    # lookup and create a second, unrelated repository. Passing the real name
    # explicitly is what makes the lookup find and push to the real one — a
    # local bare repo stands in for GitHub here so the push is real but the
    # network call is not.
    test "looks up the repository by its real name, adopts it, and pushes — creating nothing new",
         %{scope: scope, project: project, bare_dir: bare_dir} do
      stub_github(fn
        %{method: "GET", request_path: "/user"} = conn ->
          json(conn, 200, %{"login" => "johns10"})

        %{method: "GET", request_path: "/repos/johns10/market_my_spec"} = conn ->
          json(conn, 200, %{"name" => "market_my_spec", "clone_url" => bare_dir})

        %{method: "POST"} = conn ->
          flunk("created a repository instead of adopting the real one")
          conn
      end)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{repository_name: "market_my_spec"}

      assert {:reply, response, ^frame} = AdoptRepository.execute(params, frame)

      assert response.isError == false
      assert response_text(response) =~ "market_my_spec"

      # Pushed for real, to the real (stand-in) remote — not skipped, not
      # redirected to a repo nobody asked for.
      assert {log, 0} = System.cmd("git", ["log", "--oneline"], cd: bare_dir)
      assert log != ""

      project = Projects.get_project!(scope, project.id)
      assert project.code_repo == bare_dir
    end

    # John's exact worry before running this for real: adopting must never
    # sweep up in-progress local work as a side effect. `ensure_commit/1`
    # only stages/commits when there is no commit at all yet, and a plain
    # `git push` never sends anything beyond what is already committed —
    # confirmed here rather than just cited, against files that would land
    # in the real repo if that were wrong.
    test "does not commit or push uncommitted local changes or untracked files", %{
      scope: scope,
      bare_dir: bare_dir
    } do
      working_dir = scope.environment.cwd

      # A checkout that already has history, on a non-"main" default branch —
      # the shape of a real, pre-existing project rather than a fresh one.
      {_, 0} = System.cmd("git", ["init", "-b", "master"], cd: working_dir)
      {_, 0} = System.cmd("git", ["add", "-A"], cd: working_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Existing history"], cd: working_dir)

      # In-progress local work that must not end up in the real repo.
      File.write!(Path.join(working_dir, "mix.lock"), "uncommitted local change")
      File.write!(Path.join(working_dir, ".cms_harness.json"), "untracked, unrelated")

      stub_github(fn
        %{method: "GET", request_path: "/user"} = conn ->
          json(conn, 200, %{"login" => "johns10"})

        %{method: "GET", request_path: "/repos/johns10/market_my_spec"} = conn ->
          json(conn, 200, %{"name" => "market_my_spec", "clone_url" => bare_dir})

        %{method: "POST"} = conn ->
          flunk("created a repository instead of adopting the real one")
          conn
      end)

      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        repository_name: "market_my_spec",
        branch: "master"
      }

      assert {:reply, response, ^frame} = AdoptRepository.execute(params, frame)
      assert response.isError == false

      # Pushed to the branch it was told to use, not the "main" default.
      {branches, 0} = System.cmd("git", ["branch"], cd: bare_dir)
      assert branches =~ "master"

      # The pushed history has exactly the one pre-existing commit — nothing
      # for the uncommitted or untracked files, because nothing here staged
      # or committed them. Named explicitly rather than via HEAD: the bare
      # repo's HEAD still points at "main", which nothing was ever pushed to
      # in this test.
      {log, 0} = System.cmd("git", ["log", "master", "--oneline"], cd: bare_dir)
      assert log |> String.trim() |> String.split("\n") |> length() == 1

      {show, 0} = System.cmd("git", ["show", "--stat", "master"], cd: bare_dir)
      refute show =~ "mix.lock"
      refute show =~ "cms_harness"
    end

    # The exact confusion this is meant to prevent: a caller retrying blind
    # against an unchanged devops_status because the tool always said
    # "success" regardless of whether anything actually ran. A lock conflict
    # is now a distinct, honest answer instead of a silent no-op dressed up
    # as progress.
    test "reports a run already in progress instead of a false success", %{
      scope: scope,
      project: project
    } do
      test_pid = self()

      {:ok, holder} =
        Task.start(fn ->
          RunLock.with_lock(project.id, fn ->
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{repository_name: "market_my_spec"}

      assert {:reply, response, ^frame} = AdoptRepository.execute(params, frame)
      assert response.isError == true
      assert response_text(response) =~ "already in progress"

      send(holder, :release)
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end

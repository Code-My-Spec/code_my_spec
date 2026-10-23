defmodule CodeMySpec.Integration.DesktopOnboardingWorkflowTest do
  @moduledoc """
  Desktop journey through the real forms, tools, recorded setup jobs and harness
  websocket. Only model execution, host prerequisites and the external generator
  are controlled. cms_new's own generation tests cover its recipe template.
  """
  use CodeMySpecTest.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias CodeMySpec.{Agents, UserPreferences, WorkingCopies}
  alias CodeMySpec.Projects.Tools.{SetupLocalProject, UpdateProjectOnboarding}
  alias CmsHarness.Setup

  defmodule Transport do
    def start_agent(_, agent, _) do
      scope = %CodeMySpec.Users.Scope{
        active_project_id: agent.project_id,
        active_account_id: agent.account_id
      }

      {:ok, _} = Agents.Mailbox.register(scope, agent.id, Ecto.UUID.generate())
      Agents.Presence.track(self(), Agents.Presence.topic(agent.project_id), agent.id, %{})
      {:ok, %{agent_id: agent.id}}
    end

    def stop_agent(_, agent, _) do
      Agents.Presence.untrack(self(), Agents.Presence.topic(agent.project_id), agent.id)
      :ok
    end

    def dispatch_message(_, _, _, _, _), do: {:error, :busy}
  end

  defmodule Generator do
    def cmd(_, "mix", ["cms.new", root, "--app", app, "--no-install"]) do
      File.mkdir_p!(root)
      {_, 0} = System.cmd("/usr/bin/git", ["init", "--quiet", root])
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "mix.exs"),
        "defmodule Journey.MixProject do\n use Mix.Project\n def project, do: [app: :#{app}, version: \"0.1.0\", deps: []]\nend\n"
      )

      # Deliberately reproduce the stale archive: retry must repair this same
      # checkout, not lose identities or generate a second project/team.
      {:ok, "generated"}
    end
  end

  setup do
    root = CodeMySpec.TempFile.owned_dir("onboarding-journey")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    env =
      for key <- ~w(PATH CMS_PROJECT_DIR CMS_PROJECT_ID),
          into: %{},
          do: {key, System.get_env(key)}

    config = [
      env: :desktop,
      desktop_agent_transport: Transport,
      agent_transport: Transport,
      generator_runner: Generator,
      detached_agents_root: Path.join(root, "agents"),
      desktop_project_setup: {CodeMySpecDesktop.ProjectSetup, :run},
      device_config_path: Path.join(root, "device.json")
    ]

    previous = for {key, _} <- config, do: {key, Application.fetch_env(:code_my_spec, key)}
    Enum.each(config, fn {key, value} -> Application.put_env(:code_my_spec, key, value) end)
    System.put_env("CMS_PROJECT_DIR", Path.join(root, "state"))
    System.delete_env("CMS_PROJECT_ID")
    File.write!(Path.join(root, "device.json"), Jason.encode!(%{device_id: Ecto.UUID.generate()}))

    for {name, output} <- [
          {"psql", "psql 16\nvector|0.8"},
          {"mise", "erlang 28\nelixir 1.19"},
          {"erl", "28"},
          {"elixir", "Elixir 1.19"},
          {"vibium", "Vibium 1"},
          {"claude", "Claude 1"}
        ] do
      executable(bin, name, "printf '%s\\n' '#{output}'")
    end

    # Run the real just parser; substitute only the expensive generated Mix alias.
    File.ln_s!(System.find_executable("just"), Path.join(bin, "just"))

    executable(
      bin,
      "mix",
      "case \"$*\" in 'help cms.new') printf 'mix cms.new\\n' ;; setup) printf done > .dev-setup-completed ;; *) exit 1 ;; esac"
    )

    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    CmsHarnessTest.FakeServer.start()
    start_supervised!(CodeMySpecDesktop.ProjectSetup)

    on_exit(fn ->
      Enum.each(env, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:code_my_spec, k, v)
        {k, :error} -> Application.delete_env(:code_my_spec, k)
      end)

      File.rm_rf!(root)
    end)

    user =
      CodeMySpec.UsersFixtures.user_fixture(%{
        email: CodeMySpec.UserPreferences.DesktopUser.email()
      })

    %{root: root, user: user}
  end

  test "models → account → active project → Product → Main setup → same team in first checkout",
       %{conn: conn, root: root, user: user} do
    {:ok, models, _} = live(conn, "/app?provider=claude-code")
    models |> form("[data-test=agent-models-form]") |> render_submit()
    assert_redirect(models, "/app")
    {:ok, account, _} = live(conn, "/app")
    account |> form("#account_form", account: %{name: "My workspace"}) |> render_submit()
    assert_redirect(account, "/app")
    {:ok, project, _} = live(conn, "/app")
    project |> form("#project_form", project: %{name: "Journey"}) |> render_submit()
    assert_redirect(project, "/app")
    scope = UserPreferences.scope_for(user)
    assert scope.active_project.name == "Journey"
    assert WorkingCopies.main(scope) == nil

    {:error, {:live_redirect, %{to: conversation_path}}} =
      live(conn, "/app/projects/#{scope.active_project_id}/agent-conversation?role=product")

    {:ok, cockpit, _} = live(conn, conversation_path)

    assert has_element?(cockpit, "#project-definition-form")
    [product] = Agents.list_agents(scope)
    assert product.role == :product
    assert product.execution_mode == :detached
    checkout = Path.join(root, "journey")
    on_exit(fn -> CmsHarnessTest.Projects.stop_project(checkout) end)

    assert {:ok, _} =
             UpdateProjectOnboarding.script_result(
               %{
                 "description" => "Help families plan meals",
                 "starting_point" => "new",
                 "destination" => "local",
                 "destination_path" => checkout
               },
               %{scope: scope}
             )

    assert {:ok, _, main} = Agents.start_project_setup(scope)
    assert main.execution_mode == :detached
    {:ok, main_conversation} = Agents.conversation_id(scope, main.id)
    {:ok, product_conversation} = Agents.conversation_id(scope, product.id)

    check = run_setup(scope, "check")
    assert check.result["prerequisites_passed"]
    assert length(check.snapshot["steps"]) == 8
    assert Setup.prerequisites_passed?(check.snapshot)
    assert check.snapshot["steps"] == check.machine_snapshot["steps"]

    failed = run_setup(scope, "create")
    assert failed.result["ready"] == false
    assert failed.snapshot["operations"]["dev_setup"]["state"] == "errored"
    assert failed.snapshot["operations"]["dev_setup"]["error"] =~ "recipe is missing"
    copy = WorkingCopies.main(scope)
    assert copy.root == checkout
    assert_team(scope, copy, main, product, main_conversation, product_conversation)

    refute Enum.any?(Agents.list_agents(scope), & &1.continuous)

    File.write!(
      Path.join(checkout, "justfile"),
      "dev-setup:\n    /usr/bin/env MIX_ENV=dev \"#{Path.join(root, "bin/mix")}\" setup\n"
    )

    completed = run_setup(scope, "connect")

    assert completed.result["ready"] == true,
           inspect(completed.snapshot["operations"]["dev_setup"])

    assert completed.snapshot["operations"]["dev_setup"]["state"] == "done"
    assert File.read!(Path.join(checkout, ".dev-setup-completed")) == "done"
    assert WorkingCopies.main(scope).id == copy.id
    assert Enum.all?(Agents.list_agents(scope), & &1.continuous)
    assert {:ok, %{"team_activated" => true}} = Setup.project_status(scope.active_project_id)
    # Retrying/refreshing setup must not undo a deliberate pause.
    assert {:ok, _} = Agents.set_copy_continuous(scope, copy.id, false)
    assert run_setup(scope, "refresh").result["ready"] == true
    refute Enum.any?(Agents.list_agents(scope), & &1.continuous)
    assert_team(scope, copy, main, product, main_conversation, product_conversation)
    assert %{started: [], failed: []} = Agents.ensure_copy_agents(scope, copy)
  end

  defp assert_team(scope, copy, main, product, main_conversation, product_conversation) do
    agents = Agents.list_agents(scope)
    assert Enum.sort(Enum.map(agents, & &1.id)) == Enum.sort([main.id, product.id])

    assert Enum.all?(
             agents,
             &(&1.working_copy_id == copy.id and &1.execution_mode == :working_copy)
           )

    assert {:ok, ^main_conversation} = Agents.conversation_id(scope, main.id)
    assert {:ok, ^product_conversation} = Agents.conversation_id(scope, product.id)
  end

  defp run_setup(scope, action) do
    assert {:ok, _} =
             SetupLocalProject.script_result(%{action: action, app: "journey"}, %{scope: scope})

    await_setup(scope, 200)
  end

  defp await_setup(scope, remaining) do
    assert remaining > 0, "setup job did not finish"
    assert {:ok, status} = SetupLocalProject.script_result(%{action: "status"}, %{scope: scope})

    if status.running do
      Process.sleep(25)
      await_setup(scope, remaining - 1)
    else
      assert status.result["ok"], inspect(status)
      status
    end
  end

  defp executable(bin, name, script) do
    file = Path.join(bin, name)
    File.write!(file, "#!/bin/sh\n#{script}\n")
    File.chmod!(file, 0o700)
  end
end

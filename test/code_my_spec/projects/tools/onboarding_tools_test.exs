defmodule CodeMySpec.Projects.Tools.OnboardingToolsTest do
  use CodeMySpecTest.DataCase, async: false
  alias CodeMySpec.{Tools, ToolLibrary}
  alias CodeMySpec.Projects.Onboarding
  alias CodeMySpec.Projects.Tools.{GetProjectOnboarding, UpdateProjectOnboarding}

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()
    %{scope: scope, context: %{scope: scope}}
  end

  test "tools are discoverable and granted to product without a working copy", %{context: context} do
    for tool <- [GetProjectOnboarding, UpdateProjectOnboarding] do
      assert {:ok, ^tool} = ToolLibrary.fetch(tool.name())
      assert CodeMySpec.Agents.RoleProfile.carries?(:product, tool.name())
      refute CodeMySpec.Agents.RoleProfile.carries?(:coding, tool.name())

      assert Enum.any?(
               CodeMySpec.McpServers.ScriptableTools.registrations(),
               &(&1.name == tool.name())
             )

      assert is_map(Tools.input_schema(tool))
    end

    assert {:ok, text} = Tools.run(GetProjectOnboarding, %{}, context)
    assert Jason.decode!(text)["onboarding"] == %{}
  end

  test "handoff is discoverable and product can request it without a checkout", %{
    context: context
  } do
    tool = CodeMySpec.Agents.Tools.StartProjectSetup
    assert {:ok, ^tool} = ToolLibrary.fetch("start_project_setup")
    assert CodeMySpec.Agents.RoleProfile.carries?(:product, "start_project_setup")
    assert {:error, message} = Tools.run(tool, %{}, context)
    assert message =~ "First save"
  end

  test "choices tool cannot fake a completed setup handoff", %{context: context} do
    assert {:ok, _} =
             UpdateProjectOnboarding.script_result(
               %{
                 onboarding: %{
                   description: "Meal planning",
                   starting_point: "new",
                   destination: "local",
                   setup_agent_id: Ecto.UUID.generate(),
                   setup_started_at: DateTime.utc_now()
                 }
               },
               context
             )

    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.phase == :setup_handoff
    assert data.onboarding.setup_agent_id == nil
  end

  test "product can rename its project and preserve an explicitly chosen folder", %{
    context: context,
    scope: scope
  } do
    assert {:ok, text} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "name" => "Mahjong Coach",
                 "onboarding" => %{
                   "destination" => "local",
                   "destination_path" => "/Users/example/Documents/github/mahjong-coach"
                 }
               },
               context
             )

    data = Jason.decode!(text)
    assert data["name"] == "Mahjong Coach"
    assert data["onboarding"]["destination"] == "local"

    assert data["onboarding"]["destination_path"] ==
             "/Users/example/Documents/github/mahjong-coach"

    {:ok, project} = Onboarding.fetch(scope)
    assert project.name == "Mahjong Coach"

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"onboarding" => %{"description" => "A teaching game"}},
               context
             )

    {:ok, project} = Onboarding.fetch(scope)
    assert project.name == "Mahjong Coach"
    assert project.onboarding.destination_path == "/Users/example/Documents/github/mahjong-coach"
  end

  test "local default stays under CodeMySpec home and a rename does not move an explicit directory",
       %{context: context} do
    previous = Application.get_env(:code_my_spec, :env)
    Application.put_env(:code_my_spec, :env, :desktop)
    on_exit(fn -> Application.put_env(:code_my_spec, :env, previous) end)
    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"name" => "Mahjong Coach"}, context)
    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.local_directory == Path.join(CodeMySpec.Paths.projects_root(), "mahjong-coach")

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"onboarding" => %{"destination_path" => "C:\\Projects\\mahjong-coach"}},
               context
             )

    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"name" => "A new name"}, context)
    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.local_directory == "C:\\Projects\\mahjong-coach"
    Application.put_env(:code_my_spec, :env, :test)
    assert {:ok, %{local_directory: nil}} = GetProjectOnboarding.script_result(%{}, context)
  end

  test "empty names and relative destination paths are rejected", %{context: context} do
    assert {:error, _} = Tools.run(UpdateProjectOnboarding, %{"name" => " "}, context)

    assert {:error, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"onboarding" => %{"destination_path" => "../project"}},
               context
             )
  end

  test "JSON tool arguments patch choices, preserve omitted data and broadcast saved state", %{
    scope: scope,
    context: context
  } do
    :ok = Onboarding.subscribe(scope)

    assert {:ok, text} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "onboarding" => %{
                   "description" => "Meal planning",
                   "starting_point" => "existing"
                 },
                 "sources" => [
                   %{"kind" => "github", "repository_url" => "https://github.com/example/meals"}
                 ]
               },
               context
             )

    saved = Jason.decode!(text)
    assert saved["onboarding"]["description"] == "Meal planning"
    assert_receive {:project_onboarding_updated, %{id: id}}
    assert id == scope.active_project_id

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"onboarding" => %{"destination" => "local"}},
               context
             )

    {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.onboarding.description == "Meal planning"
    assert data.onboarding.destination == :local
    assert length(data.sources) == 1
    assert hd(data.sources).assessment == :pending
    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"sources" => []}, context)
    assert {:ok, %{sources: []}} = GetProjectOnboarding.script_result(%{}, context)
  end

  test "local source IDs come from accessible devices and accept Windows paths", %{
    scope: scope,
    context: context
  } do
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert Enum.any?(data.available_devices, &(&1.id == device.id))
    path = ~S(C:\Users\person\source)

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "sources" => [
                   %{"kind" => "local", "device_id" => device.id, "path" => path}
                 ]
               },
               context
             )

    {:ok, saved} = Onboarding.fetch(scope)
    assert hd(saved.sources).path == path
  end

  test "invalid and inaccessible sources return actionable errors without changing choices", %{
    scope: scope,
    context: context
  } do
    {:ok, _} = Onboarding.save(scope, %{onboarding: %{description: "Keep this"}})

    assert {:error, error} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "sources" => [
                   %{"kind" => "local", "device_id" => Ecto.UUID.generate(), "path" => "/source"}
                 ]
               },
               context
             )

    assert error =~ "accessible device"

    assert {:error, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"onboarding" => %{"destination" => "guess"}},
               context
             )

    {:ok, saved} = Onboarding.fetch(scope)
    assert saved.onboarding.description == "Keep this"
    assert saved.sources == []
  end

  test "a forged project scope cannot read or save another account's onboarding", %{scope: scope} do
    other = CodeMySpec.UsersFixtures.user_fixture()
    context = %{scope: %{scope | user: other, user_id: other.id}}
    assert {:error, _} = Tools.run(GetProjectOnboarding, %{}, context)

    assert {:error, _} =
             Tools.run(UpdateProjectOnboarding, %{onboarding: %{description: "No"}}, context)

    assert {:ok, %{onboarding: nil}} = Onboarding.fetch(scope)
  end

  test "detached product can record decisions through the real script catalog", %{scope: scope} do
    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        role: :product,
        engine: :alloy,
        provider: "claude-code",
        execution_mode: :detached,
        working_copy: System.tmp_dir!()
      })

    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    assert {:reply, response, ^frame} =
             CodeMySpec.McpServers.CodeMode.Tools.RunScript.execute(
               %{
                 script:
                   ~S[return update_project_onboarding({onboarding = {description = "A shared meal planner", starting_point = "new"}})]
               },
               frame
             )

    refute response.isError
    assert {:ok, %{onboarding: %{description: "A shared meal planner"}}} = Onboarding.fetch(scope)
  end
end

defmodule CodeMySpec.Projects.Tools.OnboardingToolsTest do
  use CodeMySpecTest.DataCase, async: false
  alias CodeMySpec.{Tools, ToolLibrary}
  alias CodeMySpec.Projects.Onboarding
  alias CodeMySpec.Projects.Tools.{GetProjectOnboarding, UpdateProjectOnboarding}

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()
    %{scope: scope, context: %{scope: scope}}
  end

  test "flat fields are discoverable in the script documentation", %{context: context} do
    for tool <- [GetProjectOnboarding, UpdateProjectOnboarding] do
      assert {:ok, ^tool} = ToolLibrary.fetch(tool.name())
      assert CodeMySpec.Agents.RoleProfile.carries?(:product, tool.name())
      refute CodeMySpec.Agents.RoleProfile.carries?(:coding, tool.name())
    end

    registration = ToolLibrary.registration(UpdateProjectOnboarding)

    catalog =
      CodeMySpec.CodeMode.Catalog.from([registration], fn _ -> fn _ -> {:ok, "ok"} end end)

    docs = CodeMySpec.CodeMode.docs(catalog, name: "update_project_onboarding")

    for field <-
          ~w(name description starting_point destination destination_path source_action source_id source_kind repository_url ref device_id path) do
      assert docs =~ "#{field} ("
    end

    for {name, schema} <- registration.input_schema["properties"], name != "sources" do
      refute schema["type"] in ["object", "array"]
    end

    assert {:ok, text} = Tools.run(GetProjectOnboarding, %{}, context)
    assert Jason.decode!(text)["onboarding"] == %{}
  end

  test "handoff remains gated until required choices exist", %{context: context} do
    tool = CodeMySpec.Agents.Tools.StartProjectSetup
    assert {:ok, ^tool} = ToolLibrary.fetch("start_project_setup")
    assert {:error, message} = Tools.run(tool, %{}, context)
    assert message =~ "First save"
  end

  test "nested, invented and server-owned fields are rejected before partial saves", %{
    context: context
  } do
    for invalid <- [
          %{"onboarding" => %{"destination" => "local"}},
          %{"development_destination" => %{"kind" => "local"}},
          %{"setup_agent_id" => Ecto.UUID.generate()}
        ] do
      assert {:error, error} =
               Tools.run(
                 UpdateProjectOnboarding,
                 Map.put(invalid, "description", "Not saved"),
                 context
               )

      assert error =~ "top level"
      assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
      assert data.onboarding == %{}
    end
  end

  test "flat updates rename, patch choices and broadcast without losing the selected path", %{
    context: context,
    scope: scope
  } do
    :ok = Onboarding.subscribe(scope)

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "name" => "Mahjong Coach",
                 "description" => "Mahjong tutor",
                 "starting_point" => "new",
                 "destination" => "local",
                 "destination_path" => "/Users/example/mahjong-coach"
               },
               context
             )

    assert_receive {:project_onboarding_updated, %{id: id}}
    assert id == scope.active_project_id

    assert {:ok, _} =
             Tools.run(UpdateProjectOnboarding, %{"description" => "A teaching game"}, context)

    assert {:ok, saved} = Onboarding.fetch(scope)
    assert saved.name == "Mahjong Coach"
    assert saved.onboarding.description == "A teaching game"
    assert saved.onboarding.destination == :local
    assert saved.onboarding.destination_path == "/Users/example/mahjong-coach"
    assert Onboarding.phase(saved) == :setup_handoff
  end

  test "source additions and edits preserve choices and other sources", %{
    context: context,
    scope: scope
  } do
    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"description" => "Tutor", "starting_point" => "new", "destination" => "local"},
               context
             )

    assert {:ok, before} = Onboarding.fetch(scope)

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"source_kind" => "github", "repository_url" => "https://github.com/KDE/kajongg"},
               context
             )

    assert {:ok, first} = Onboarding.fetch(scope)
    [source] = first.sources

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 "source_kind" => "github",
                 "repository_url" => "https://github.com/example/another"
               },
               context
             )

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"source_id" => source.id, "ref" => "main"},
               context
             )

    assert {:ok, saved} = Onboarding.fetch(scope)
    assert saved.onboarding == before.onboarding
    assert [updated, other] = saved.sources
    assert updated.id == source.id
    assert updated.repository_url == source.repository_url
    assert updated.ref == "main"
    assert other.repository_url == "https://github.com/example/another"

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"source_action" => "remove", "source_id" => source.id},
               context
             )

    assert {:ok, saved} = Onboarding.fetch(scope)
    assert [^other] = saved.sources
    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"source_action" => "clear"}, context)
    assert {:ok, %{sources: []}} = Onboarding.fetch(scope)
  end

  test "batch sources merge atomically and preserve unmentioned sources and choices", %{
    context: context,
    scope: scope
  } do
    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 description: "Tutor",
                 starting_point: "new",
                 destination: "local",
                 source_kind: "github",
                 repository_url: "https://github.com/example/keep"
               },
               context
             )

    {:ok, before} = Onboarding.fetch(scope)
    [original] = before.sources

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{
                 sources: [
                   %{kind: "github", repository_url: "https://github.com/KDE/kajongg"},
                   %{kind: "github", repository_url: "https://github.com/FluffyStuff/OpenRiichi"}
                 ]
               },
               context
             )

    {:ok, saved} = Onboarding.fetch(scope)
    assert saved.onboarding == before.onboarding
    assert [^original, kajongg, riichi] = saved.sources
    assert kajongg.repository_url != riichi.repository_url

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{sources: [%{id: kajongg.id, ref: "main"}]},
               context
             )

    {:ok, edited} = Onboarding.fetch(scope)
    assert [^original, %{ref: "main"}, ^riichi] = edited.sources
    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{sources: []}, context)
    assert {:ok, ^edited} = Onboarding.fetch(scope)

    for invalid <- [
          %{sources: [%{id: kajongg.id, ref: "changed"}, %{kind: "local"}]},
          %{sources: [%{kind: "github", repository_urll: "typo"}]},
          %{sources: [], source_action: "clear"},
          %{sources: [%{id: Ecto.UUID.generate(), ref: "main"}]}
        ] do
      assert {:error, _} = Tools.run(UpdateProjectOnboarding, invalid, context)
      assert {:ok, ^edited} = Onboarding.fetch(scope)
    end
  end

  test "local sources use accessible devices and Windows paths", %{context: context, scope: scope} do
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    path = ~S(C:\Users\person\source)

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"source_kind" => "local", "device_id" => device.id, "path" => path},
               context
             )

    assert {:ok, saved} = Onboarding.fetch(scope)
    assert hd(saved.sources).path == path
    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert Enum.any?(data.available_devices, &(&1.id == device.id))
  end

  test "invalid sources, IDs, names and destinations leave saved data intact", %{
    context: context,
    scope: scope
  } do
    {:ok, _} = Onboarding.save(scope, %{onboarding: %{description: "Keep this"}})

    for invalid <- [
          %{"source_kind" => "local", "device_id" => Ecto.UUID.generate(), "path" => "/source"},
          %{"source_id" => Ecto.UUID.generate(), "ref" => "main"},
          %{"source_action" => "remove"},
          %{"source_kind" => "github"},
          %{"destination" => "guess"},
          %{"name" => " "},
          %{"destination_path" => "../project"}
        ] do
      assert {:error, _} = Tools.run(UpdateProjectOnboarding, invalid, context)
    end

    assert {:ok, saved} = Onboarding.fetch(scope)
    assert saved.onboarding.description == "Keep this"
    assert saved.sources == []
  end

  test "desktop defaults and explicit Windows destinations survive renames", %{context: context} do
    previous = Application.get_env(:code_my_spec, :env)
    Application.put_env(:code_my_spec, :env, :desktop)
    on_exit(fn -> Application.put_env(:code_my_spec, :env, previous) end)
    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"name" => "Mahjong Coach"}, context)
    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.local_directory == Path.join(CodeMySpec.Paths.projects_root(), "mahjong-coach")

    assert {:ok, _} =
             Tools.run(
               UpdateProjectOnboarding,
               %{"destination_path" => ~S(C:\Projects\mahjong-coach)},
               context
             )

    assert {:ok, _} = Tools.run(UpdateProjectOnboarding, %{"name" => "Renamed"}, context)
    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, context)
    assert data.local_directory == ~S(C:\Projects\mahjong-coach)
    Application.put_env(:code_my_spec, :env, :test)
    assert {:ok, %{local_directory: nil}} = GetProjectOnboarding.script_result(%{}, context)
  end

  test "another user cannot update the project", %{scope: scope} do
    other = CodeMySpec.UsersFixtures.user_fixture()
    context = %{scope: %{scope | user: other, user_id: other.id}}
    assert {:error, _} = Tools.run(GetProjectOnboarding, %{}, context)
    assert {:error, _} = Tools.run(UpdateProjectOnboarding, %{description: "No"}, context)
    assert {:ok, %{onboarding: nil}} = Onboarding.fetch(scope)
  end

  test "Main can read and update onboarding through Lua after setup handoff", %{scope: scope} do
    {:ok, agent} =
      CodeMySpec.Agents.AgentsRepository.create_agent(scope, %{
        role: :main,
        engine: :alloy,
        provider: "claude-code",
        execution_mode: :detached,
        working_copy: System.tmp_dir!()
      })

    {:ok, _} =
      Onboarding.save(scope, %{
        onboarding: %{description: "Tutor", starting_point: "new", destination: "local"}
      })

    {:ok, handed_off} = Onboarding.record_handoff(scope, agent.id)
    timestamp = DateTime.to_iso8601(handed_off.onboarding.setup_started_at)
    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    for script <- [
          "return get_project_onboarding({})",
          ~S[return update_project_onboarding({description = "Mahjong tutor"})]
        ] do
      assert {:reply, response, ^frame} =
               CodeMySpec.McpServers.CodeMode.Tools.RunScript.execute(%{script: script}, frame)

      refute response.isError
      assert Enum.map_join(response.content, "", & &1["text"]) =~ timestamp
    end

    assert {:ok, data} = GetProjectOnboarding.script_result(%{}, %{scope: scope})
    assert data.onboarding.setup_started_at == timestamp
    assert data.phase == :stories
    assert {:ok, saved} = Onboarding.fetch(scope)
    assert %DateTime{} = saved.onboarding.setup_started_at
    assert saved.onboarding.setup_started_at == handed_off.onboarding.setup_started_at
  end

  test "detached product saves flat arguments through the actual script catalog", %{scope: scope} do
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
                   ~S[return update_project_onboarding({description = "A shared meal planner", starting_point = "new", destination = "local", sources = {{kind = "github", repository_url = "https://github.com/example/meals"}, {kind = "github", repository_url = "https://github.com/example/recipes"}}})]
               },
               frame
             )

    refute response.isError
    assert {:ok, project} = Onboarding.fetch(scope)
    assert project.onboarding.destination == :local
    assert project.onboarding.starting_point == :new
    assert length(project.sources) == 2
  end
end

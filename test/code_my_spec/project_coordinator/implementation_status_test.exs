defmodule CodeMySpec.ProjectCoordinator.ImplementationStatusTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.ProjectCoordinator.ImplementationStatus
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.Requirement

  describe "match_task/2" do
    test "matches task with overlapping files" do
      tasks = [
        %{
          "component_id" => "aaa",
          "requirement" => "implementation_file",
          "expected_files" => ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]
        },
        %{
          "component_id" => "bbb",
          "requirement" => "implementation_file",
          "expected_files" => ["lib/my_app/users.ex", "test/my_app/users_test.exs"]
        }
      ]

      edited = ["lib/my_app/users.ex", "test/my_app/users_test.exs"]
      matched = ImplementationStatus.match_task(edited, tasks)

      assert matched["component_id"] == "bbb"
    end

    test "returns task with most overlap when multiple match" do
      tasks = [
        %{
          "component_id" => "aaa",
          "expected_files" => ["lib/my_app/accounts.ex"]
        },
        %{
          "component_id" => "bbb",
          "expected_files" => ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]
        }
      ]

      edited = ["lib/my_app/accounts.ex", "test/my_app/accounts_test.exs"]
      matched = ImplementationStatus.match_task(edited, tasks)

      assert matched["component_id"] == "bbb"
    end

    test "returns nil when no files overlap" do
      tasks = [
        %{
          "component_id" => "aaa",
          "expected_files" => ["lib/my_app/accounts.ex"]
        }
      ]

      assert ImplementationStatus.match_task(["lib/other/thing.ex"], tasks) == nil
    end

    test "returns nil for empty tasks list" do
      assert ImplementationStatus.match_task(["lib/foo.ex"], []) == nil
    end

    test "handles tasks with no expected_files key" do
      tasks = [%{"component_id" => "aaa"}]
      assert ImplementationStatus.match_task(["lib/foo.ex"], tasks) == nil
    end
  end

  describe "expected_files_for/3" do
    setup do
      component = %Component{
        id: "test-id",
        module_name: "MyApp.Accounts",
        type: "context",
        name: "Accounts"
      }

      project = %Project{
        id: "proj-id",
        name: "my_app",
        module_name: "MyApp"
      }

      %{component: component, project: project}
    end

    test "spec requirements return spec file", %{component: component, project: project} do
      req = %Requirement{name: "spec_file", scope: :local}
      files = ImplementationStatus.expected_files_for(req, component, project)

      assert length(files) == 1
      assert hd(files) =~ "spec"
      assert hd(files) =~ "accounts"
    end

    test "implementation requirements return code + test", %{
      component: component,
      project: project
    } do
      req = %Requirement{name: "implementation_file", scope: :local}
      files = ImplementationStatus.expected_files_for(req, component, project)

      assert length(files) == 2
      assert Enum.any?(files, &(&1 =~ "lib/"))
      assert Enum.any?(files, &(&1 =~ "test/"))
    end

    test "test requirements return test file only", %{component: component, project: project} do
      req = %Requirement{name: "test_file", scope: :local}
      files = ImplementationStatus.expected_files_for(req, component, project)

      assert length(files) == 1
      assert hd(files) =~ "test/"
    end

    test "children scope returns all files", %{component: component, project: project} do
      req = %Requirement{name: "children_implementations", scope: :children}
      files = ImplementationStatus.expected_files_for(req, component, project)

      assert length(files) >= 3
    end
  end

  describe "build_task_entry/4" do
    test "builds entry with component" do
      req = %Requirement{
        name: "implementation_file",
        component_id: "comp-1",
        story_id: nil,
        project_id: "proj-1",
        scope: :local
      }

      component = %Component{
        id: "comp-1",
        module_name: "MyApp.Accounts",
        type: "context",
        name: "Accounts"
      }

      project = %Project{id: "proj-1", name: "my_app", module_name: "MyApp"}

      entry = ImplementationStatus.build_task_entry(req, component, project)

      assert entry["requirement"] == "implementation_file"
      assert entry["component_id"] == "comp-1"
      assert entry["component_module"] == "MyApp.Accounts"
      assert is_list(entry["expected_files"])
      assert entry["dispatched_at"]
    end

    test "builds entry without component" do
      req = %Requirement{
        name: "all_stories_complete",
        component_id: nil,
        story_id: nil,
        project_id: "proj-1",
        scope: :local
      }

      entry = ImplementationStatus.build_task_entry(req, nil, %Project{id: "proj-1"})

      assert entry["requirement"] == "all_stories_complete"
      assert entry["component_id"] == nil
      refute Map.has_key?(entry, "expected_files")
    end

    test "includes prompt_path when provided" do
      req = %Requirement{
        name: "implementation_file",
        component_id: "comp-1",
        story_id: nil,
        project_id: "proj-1",
        scope: :orchestrate
      }

      component = %Component{
        id: "comp-1",
        module_name: "MyApp.Accounts",
        type: "context",
        name: "Accounts"
      }

      project = %Project{id: "proj-1", name: "my_app", module_name: "MyApp"}

      entry =
        ImplementationStatus.build_task_entry(req, component, project,
          prompt_path: ".code_my_spec/tasks/develop/MyApp.Accounts_component_code.md"
        )

      assert entry["prompt_path"] ==
               ".code_my_spec/tasks/develop/MyApp.Accounts_component_code.md"
    end

    test "omits prompt_path when not provided" do
      req = %Requirement{
        name: "implementation_file",
        component_id: nil,
        story_id: nil,
        project_id: "proj-1",
        scope: :local
      }

      entry = ImplementationStatus.build_task_entry(req, nil, %Project{id: "proj-1"})
      refute Map.has_key?(entry, "prompt_path")
    end
  end

  describe "identify_task_from_transcript/2" do
    @tag :tmp_dir
    test "matches task by prompt_path in initial user message", %{tmp_dir: tmp_dir} do
      # Write a transcript where the first user message contains the prompt path
      transcript_path = Path.join(tmp_dir, "transcript.jsonl")

      user_entry =
        Jason.encode!(%{
          "type" => "user",
          "uuid" => "u1",
          "timestamp" => "2026-03-14T00:00:00Z",
          "sessionId" => "s1",
          "message" => %{
            "role" => "user",
            "content" => ".code_my_spec/tasks/develop/MyApp.Accounts_component_code.md"
          }
        })

      File.write!(transcript_path, user_entry <> "\n")

      # Set up a fake environment with dispatched tasks
      env_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(env_dir)
      status_dir = Path.join(env_dir, ".code_my_spec/status")
      File.mkdir_p!(status_dir)

      env = Environment.new(:local, env_dir)

      tasks = [
        %{
          "requirement" => "implementation_file",
          "component_id" => "aaa",
          "component_module" => "MyApp.Accounts",
          "prompt_path" => ".code_my_spec/tasks/develop/MyApp.Accounts_component_code.md",
          "expected_files" => ["lib/my_app/accounts.ex"]
        },
        %{
          "requirement" => "test_file",
          "component_id" => "bbb",
          "component_module" => "MyApp.Users",
          "prompt_path" => ".code_my_spec/tasks/develop/MyApp.Users_component_test.md",
          "expected_files" => ["test/my_app/users_test.exs"]
        }
      ]

      data = Jason.encode!(%{"dispatched_tasks" => tasks, "updated_at" => "2026-03-14"})
      Environments.write_file(env, Paths.implementation_status_path(), data)

      matched = ImplementationStatus.identify_task_from_transcript(env, transcript_path)
      assert matched["component_module"] == "MyApp.Accounts"
      assert matched["requirement"] == "implementation_file"
    end

    @tag :tmp_dir
    test "returns nil when no dispatched tasks exist", %{tmp_dir: tmp_dir} do
      transcript_path = Path.join(tmp_dir, "transcript.jsonl")

      user_entry =
        Jason.encode!(%{
          "type" => "user",
          "uuid" => "u1",
          "timestamp" => "2026-03-14T00:00:00Z",
          "sessionId" => "s1",
          "message" => %{"role" => "user", "content" => "some prompt"}
        })

      File.write!(transcript_path, user_entry <> "\n")

      env_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(env_dir)
      env = Environment.new(:local, env_dir)

      assert ImplementationStatus.identify_task_from_transcript(env, transcript_path) == nil
    end

    @tag :tmp_dir
    test "returns nil when transcript cannot be parsed", %{tmp_dir: tmp_dir} do
      transcript_path = Path.join(tmp_dir, "bad.jsonl")
      File.write!(transcript_path, "not json at all\n")

      env_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(env_dir)
      env = Environment.new(:local, env_dir)

      status_path = Paths.implementation_status_path()
      tasks = [%{"requirement" => "test", "prompt_path" => "some/path.md"}]
      data = Jason.encode!(%{"dispatched_tasks" => tasks, "updated_at" => "2026-03-14"})
      Environments.write_file(env, status_path, data)

      assert ImplementationStatus.identify_task_from_transcript(env, transcript_path) == nil
    end
  end

  describe "extract_initial_prompt/1" do
    @tag :tmp_dir
    test "extracts string content from first user message", %{tmp_dir: tmp_dir} do
      transcript_path = Path.join(tmp_dir, "transcript.jsonl")

      entry =
        Jason.encode!(%{
          "type" => "user",
          "uuid" => "u1",
          "timestamp" => "2026-03-14T00:00:00Z",
          "sessionId" => "s1",
          "message" => %{"role" => "user", "content" => "hello world"}
        })

      File.write!(transcript_path, entry <> "\n")

      assert ImplementationStatus.extract_initial_prompt(transcript_path) == "hello world"
    end

    @tag :tmp_dir
    test "extracts text from content blocks", %{tmp_dir: tmp_dir} do
      transcript_path = Path.join(tmp_dir, "transcript.jsonl")

      entry =
        Jason.encode!(%{
          "type" => "user",
          "uuid" => "u1",
          "timestamp" => "2026-03-14T00:00:00Z",
          "sessionId" => "s1",
          "message" => %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "path/to/prompt.md"}
            ]
          }
        })

      File.write!(transcript_path, entry <> "\n")

      assert ImplementationStatus.extract_initial_prompt(transcript_path) == "path/to/prompt.md"
    end

    @tag :tmp_dir
    test "returns nil for nonexistent file", %{tmp_dir: tmp_dir} do
      assert ImplementationStatus.extract_initial_prompt(
               Path.join(tmp_dir, "nope.jsonl")
             ) == nil
    end
  end
end

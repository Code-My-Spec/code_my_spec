defmodule CodeMySpec.ProjectCoordinatorTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.ProjectCoordinator

  defmodule ValidTask do
    def command(_scope, _session), do: {:ok, "prompt"}
    def evaluate(_scope, _task), do: {:ok, :valid}
  end

  defmodule InvalidTask do
    def command(_scope, _task) do
      send(self(), :command_called)
      {:ok, "prompt"}
    end

    def evaluate(_scope, _task) do
      send(self(), :evaluate_called)
      {:ok, :invalid, "feedback"}
    end
  end

  test "empty prompt generation succeeds without an environment" do
    assert {:ok, []} = ProjectCoordinator.generate_prompt_files(%{}, %{}, [], "prompts")
  end

  test "prompt generation uses the explicit environment despite stale scope state" do
    root = CodeMySpec.TempFile.owned_dir("coordinator_explicit_environment")
    env = Environment.new(:local, root)
    scope = %{full_scope_fixture() | environment: nil}
    component = %{module_name: "Sample.Accounts"}
    session = %{project: scope.active_project}

    assert {:ok, [%{file_path: file_path}]} =
             ProjectCoordinator.generate_prompt_files(
               scope,
               session,
               [%{component: component, task_module: ValidTask}],
               "prompts",
               environment: env
             )

    assert File.read!(Path.join(root, file_path)) == "prompt"
  end

  test "prompt generation resolves and uses the selected working copy" do
    scope = working_copy_scope_fixture()
    selected_root = scope.environment.cwd
    stale_root = CodeMySpec.TempFile.owned_dir("coordinator_stale_environment")
    scope = %{scope | environment: Environment.new(:local, stale_root)}
    component = %{module_name: "Sample.Accounts"}

    assert {:ok, [%{file_path: file_path}]} =
             ProjectCoordinator.generate_prompt_files(
               scope,
               %{project: scope.active_project},
               [%{component: component, task_module: ValidTask}],
               "prompts"
             )

    assert File.read!(Path.join(selected_root, file_path)) == "prompt"
    refute File.exists?(Path.join(stale_root, file_path))
  end

  test "an invalid selected working copy does not fall back to the stale scope environment" do
    root = CodeMySpec.TempFile.owned_dir("coordinator_invalid_selection")
    stale = Environment.new(:local, root)

    scope = %{
      full_scope_fixture()
      | active_working_copy_id: "missing-working-copy",
        environment: stale
    }

    assert {:error, :no_environment} =
             ProjectCoordinator.generate_prompt_files(
               scope,
               %{project: scope.active_project},
               [%{component: %{module_name: "Sample.Accounts"}, task_module: ValidTask}],
               "prompts"
             )

    refute File.exists?(Path.join(root, "prompts"))

    assert {:error, :no_environment} =
             ProjectCoordinator.write_prompt_file(
               scope,
               %{module_name: "Sample.Accounts"},
               ValidTask,
               "prompt",
               status_dir: "prompts"
             )

    refute File.exists?(Path.join(root, "prompts"))
  end

  test "completion cleanup deletes files only from the explicitly selected environment" do
    selected_root = CodeMySpec.TempFile.owned_dir("coordinator_cleanup_selected")
    stale_root = CodeMySpec.TempFile.owned_dir("coordinator_cleanup_stale")
    selected = Environment.new(:local, selected_root)
    stale = Environment.new(:local, stale_root)
    scope = %{full_scope_fixture() | environment: stale}
    status_dir = "prompts"
    prompt_path = Path.join(status_dir, "accounts_valid_task.md")
    problem_path = Path.join(status_dir, "accounts_valid_task_problems.md")

    Enum.each([selected_root, stale_root], fn root ->
      File.mkdir_p!(Path.join(root, status_dir))
      File.write!(Path.join(root, prompt_path), "prompt")
      File.write!(Path.join(root, problem_path), "problem")
    end)

    assert {:ok, %{complete: true}} =
             ProjectCoordinator.default_orchestrate(
               ValidTask,
               scope,
               %{component_module_name: "Accounts"},
               status_dir: status_dir,
               environment: selected
             )

    refute File.exists?(Path.join(selected_root, prompt_path))
    refute File.exists?(Path.join(selected_root, problem_path))
    assert File.exists?(Path.join(stale_root, prompt_path))
    assert File.exists?(Path.join(stale_root, problem_path))
  end

  test "complete orchestration keeps its success result with no environment" do
    root = CodeMySpec.TempFile.owned_dir("coordinator_no_environment_completion")
    scope = %{full_scope_fixture() | environment: Environment.new(:local, root)}
    status_dir = "prompts"
    prompt_path = Path.join(status_dir, "accounts_valid_task.md")
    File.mkdir_p!(Path.dirname(Path.join(root, prompt_path)))
    File.write!(Path.join(root, prompt_path), "prompt")

    assert {:ok, %{complete: true}} =
             ProjectCoordinator.default_orchestrate(
               ValidTask,
               scope,
               %{component_module_name: "Accounts"},
               status_dir: status_dir,
               environment: nil
             )

    assert File.exists?(Path.join(root, prompt_path))
  end

  test "incomplete orchestration evaluates but does not prompt or write without an environment" do
    scope = full_scope_fixture()

    assert {:error, :no_environment} =
             ProjectCoordinator.default_orchestrate(
               InvalidTask,
               scope,
               %{component_module_name: "Accounts"},
               status_dir: "prompts",
               environment: nil
             )

    assert_received :evaluate_called
    refute_received :command_called

    assert {:error, :no_environment} =
             ProjectCoordinator.default_orchestrate_evaluate(
               InvalidTask,
               scope,
               %{component_module_name: "Accounts"},
               status_dir: "prompts",
               environment: nil
             )

    assert_received :evaluate_called
  end
end

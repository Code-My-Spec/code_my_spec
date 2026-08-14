defmodule CodeMySpec.AgentTasks.QaIntegrationPlanTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaIntegrationPlan
  alias CodeMySpec.Environments.Environment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_task(context) do
    task = %{project_id: context.scope.active_project.id, component_id: nil, story_id: nil}
    Map.put(context, :task, task)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_decision(env, name, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/architecture/decisions/#{name}.md",
      content || """
      # #{String.capitalize(name)}

      ## Status

      Accepted

      ## Context

      We need #{name} for the project.

      ## Decision

      Use #{name} with API token authentication.

      ## Consequences

      - Need to manage API credentials
      """
    )
  end

  defp write_integration_index(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/integrations.md",
      content || """
      # Integrations

      | Integration | Auth Type | Status |
      |---|---|---|
      | twilio | api_token | verified |
      """
    )
  end

  defp write_integration_spec(env, name, opts \\ []) do
    status = Keyword.get(opts, :status, "verified")

    write_file!(
      env,
      ".code_my_spec/integrations/#{name}.md",
      """
      # #{String.capitalize(name)} Integration

      ## Auth Type

      api_token

      ## Required Credentials

      - `#{String.upcase(name)}_API_KEY` — API key

      ## Verify Script

      `.code_my_spec/qa/scripts/verify_#{name}.sh`

      ## Status

      #{status}
      """
    )
  end

  defp write_verify_script(env, name) do
    write_file!(env, ".code_my_spec/qa/scripts/verify_#{name}.sh", """
    #!/bin/bash
    echo '{"integration": "#{name}", "status": "ok"}'
    """)
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes integration spec format", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert prompt =~ "Integration Spec Format"
      assert prompt =~ "Auth Type"
      assert prompt =~ "Required Credentials"
    end

    test "includes decisions when they exist", %{scope: scope, task: task} do
      write_decision(scope.environment, "twilio")

      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert prompt =~ "twilio"
      assert prompt =~ "Technical Decisions"
    end

    test "handles no decisions gracefully", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert prompt =~ "No decision records found"
    end

    test "includes existing specs when present", %{scope: scope, task: task} do
      write_integration_spec(scope.environment, "twilio")

      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert prompt =~ "Existing Integration Specs"
    end

    test "points at the playbook for verify-script details", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaIntegrationPlan.command(scope, task)
      assert prompt =~ ~r/verify script/i
      assert prompt =~ "qa_integration_plan/workflow.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when all integrations verified", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      write_verify_script(env, "twilio")

      assert {:ok, :valid} = QaIntegrationPlan.evaluate(scope, task)
    end

    test "returns {:ok, :valid} when no integrations needed", %{
      scope: scope,
      task: task
    } do
      write_integration_index(
        scope.environment,
        "# Integrations\n\nNo integrations required for this project."
      )

      assert {:ok, :valid} = QaIntegrationPlan.evaluate(scope, task)
    end

    test "returns {:ok, :valid} when index missing but no specs", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :valid} = QaIntegrationPlan.evaluate(scope, task)
    end

    test "returns {:ok, :valid} when no specs exist", %{
      scope: scope,
      task: task
    } do
      write_integration_index(scope.environment)

      assert {:ok, :valid} = QaIntegrationPlan.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when verify script missing", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")

      assert {:ok, :invalid, feedback} = QaIntegrationPlan.evaluate(scope, task)
      assert feedback =~ "missing"
    end

    test "returns {:ok, :invalid, feedback} when not yet verified", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "pending")
      write_verify_script(env, "twilio")

      assert {:ok, :invalid, feedback} = QaIntegrationPlan.evaluate(scope, task)
      assert feedback =~ "not yet verified"
    end
  end
end

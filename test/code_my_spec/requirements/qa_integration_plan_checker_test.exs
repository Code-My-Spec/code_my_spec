defmodule CodeMySpec.Requirements.QaIntegrationPlanCheckerTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Requirements.QaIntegrationPlanChecker
  alias CodeMySpec.Requirements.RequirementDefinition

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_definition(_context) do
    {:ok, definition} =
      RequirementDefinition.new(%{
        name: "qa_integration_plan",
        checker: QaIntegrationPlanChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaIntegrationPlan,
        artifact_type: :specification,
        description: "Integration specs exist and all verified",
        prerequisites: ["technical_strategy"]
      })

    %{definition: definition}
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
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
    script_path = ".code_my_spec/qa/scripts/verify_#{name}.sh"

    write_file!(
      env,
      ".code_my_spec/integrations/#{name}.md",
      """
      # #{String.capitalize(name)} Integration

      ## Auth Type

      api_token

      ## Required Credentials

      - `#{String.upcase(name)}_API_KEY` — API key from the #{name} dashboard

      ## Verify Script

      `#{script_path}`

      ## Status

      #{status}
      """
    )

    script_path
  end

  defp write_verify_script(env, name) do
    script_path = ".code_my_spec/qa/scripts/verify_#{name}.sh"

    write_file!(env, script_path, """
    #!/bin/bash
    echo '{"integration": "#{name}", "status": "ok", "details": "Test passed"}'
    """)

    script_path
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "check/4" do
    setup [:create_scope, :create_definition]

    test "satisfied when all integrations verified", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      write_verify_script(env, "twilio")

      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == true
      assert result.score == 1.0
      assert result.details.integration_count == 1
    end

    test "satisfied with multiple integrations all verified", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      write_verify_script(env, "twilio")
      write_integration_spec(env, "stripe", status: "verified")
      write_verify_script(env, "stripe")

      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == true
      assert result.details.integration_count == 2
    end

    test "not satisfied when integration index missing", %{
      scope: scope,
      definition: definition
    } do
      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "Integration index missing"
    end

    test "not satisfied when no integration specs exist", %{
      scope: scope,
      definition: definition
    } do
      write_integration_index(scope.environment)

      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "No integration specs found"
    end

    test "not satisfied when verify script missing", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      # Don't write the verify script

      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "Verify script missing"
    end

    test "not satisfied when integration not verified", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "pending")
      write_verify_script(env, "twilio")

      result = QaIntegrationPlanChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "not yet verified"
    end
  end
end

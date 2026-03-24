defmodule CodeMySpec.Requirements.QaPreflightCheckerTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Requirements.QaPreflightChecker
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
        name: "qa_preflight",
        checker: QaPreflightChecker,
        satisfied_by: CodeMySpec.AgentTasks.QaPreflight,
        artifact_type: :review,
        description: "App-level integration verification complete",
        prerequisites: ["all_stories_complete"]
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

      | Integration | Status |
      |---|---|
      | twilio | verified |
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

  defp write_preflight_report(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/preflight.md",
      content || """
      # Preflight Report

      All integrations verified against the running application.

      ## Twilio

      Status: pass
      Verified SMS sending works end-to-end.
      """
    )
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "check/4" do
    setup [:create_scope, :create_definition]

    test "satisfied when all integrations verified and report exists", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      write_preflight_report(env)

      result = QaPreflightChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == true
      assert result.score == 1.0
    end

    test "satisfied when no integrations needed and report exists", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env, "# Integrations\n\nNo integrations required for this project.")
      write_preflight_report(env, "# Preflight Report\n\nNo integrations to verify.")

      result = QaPreflightChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == true
    end

    test "not satisfied when integration index missing", %{
      scope: scope,
      definition: definition
    } do
      result = QaPreflightChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "Integration index missing"
    end

    test "not satisfied when preflight report missing", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      # No preflight report

      result = QaPreflightChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "Preflight report missing"
    end

    test "not satisfied when integration not verified", %{
      scope: scope,
      definition: definition
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "configured")
      write_preflight_report(env)

      result = QaPreflightChecker.check(scope, definition, scope.active_project)

      assert result.satisfied == false
      assert result.details.reason =~ "not verified"
    end
  end
end

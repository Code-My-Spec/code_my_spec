defmodule CodeMySpec.AgentTasks.QaPreflightTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaPreflight
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

  defp write_preflight_report(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/preflight.md",
      content || """
      # Preflight Report

      All integrations verified against the running application.

      ## Twilio

      Status: pass
      """
    )
  end

  defp write_qa_plan(env) do
    write_file!(env, ".code_my_spec/qa/plan.md", """
    # QA Plan

    ## App Overview

    Phoenix app on port 4000.

    ## Tools Registry

    ### web tool
    Use for LiveView pages.

    ## Seed Strategy

    Run `mix run priv/repo/qa_seeds.exs`.
    """)
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes preflight header", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert prompt =~ "QA Preflight"
      assert prompt =~ "App-Level Integration Verification"
    end

    test "includes integration specs when present", %{scope: scope, task: task} do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio")

      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert prompt =~ "twilio"
    end

    test "handles no integration specs", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert prompt =~ "No integration specs found"
    end

    test "references QA plan when it exists", %{scope: scope, task: task} do
      write_qa_plan(scope.environment)

      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert prompt =~ "QA Plan"
      assert prompt =~ "plan.md"
    end

    test "includes verification instructions", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaPreflight.command(scope, task)
      assert prompt =~ "Verify Each Integration"
      assert prompt =~ "preflight.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when report exists and integrations verified", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "verified")
      write_preflight_report(env)

      assert {:ok, :valid} = QaPreflight.evaluate(scope, task)
    end

    test "returns {:ok, :valid} when no integrations and report exists", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env, "# Integrations\n\nNo integrations required.")
      write_preflight_report(env, "# Preflight\n\nNo integrations to verify.")

      assert {:ok, :valid} = QaPreflight.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when report missing", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :invalid, feedback} = QaPreflight.evaluate(scope, task)
      assert feedback =~ "Preflight report not found"
    end

    test "returns {:ok, :invalid, feedback} when integration not verified", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_integration_index(env)
      write_integration_spec(env, "twilio", status: "configured")
      write_preflight_report(env)

      assert {:ok, :invalid, feedback} = QaPreflight.evaluate(scope, task)
      assert feedback =~ "not verified"
    end

    test "returns {:ok, :invalid, feedback} when index missing", %{
      scope: scope,
      task: task
    } do
      env = scope.environment
      write_preflight_report(env)

      assert {:ok, :invalid, feedback} = QaPreflight.evaluate(scope, task)
      assert feedback =~ "Integration index missing"
    end
  end
end

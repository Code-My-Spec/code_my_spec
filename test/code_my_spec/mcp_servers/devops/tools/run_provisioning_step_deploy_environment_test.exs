defmodule CodeMySpec.McpServers.Devops.Tools.RunProvisioningStepDeployEnvironmentTest do
  @moduledoc """
  Confirmed live against cleaner_crm: two calls to `run_provisioning_step`
  with `step: "deploy"` and no `:environment` both deployed prod first
  (`deploy_environments/3` has no defined ordering it promises) and never
  reached uat at all, since a halt on the first failure stops the whole
  batch. John was explicit afterward: a deploy call must always name the one
  environment it means. This is the refusal that makes that true — before
  `Steps.run/3` is ever reached, not a convention callers have to remember.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Provisioning.EnvironmentRepository

  setup do
    scope = full_scope_fixture()
    {:ok, _} = EnvironmentRepository.put(scope, "prod", %{})
    {:ok, _} = EnvironmentRepository.put(scope, "uat", %{})
    %{scope: scope}
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  test "refuses a deploy with no environment named, before touching either one", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} = RunProvisioningStep.execute(%{step: "deploy"}, frame)

    text = response_text(response)
    assert text =~ "needs :environment"
    assert text =~ "never all of them at once"
  end

  test "an empty environment string is refused the same as a missing one", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} =
             RunProvisioningStep.execute(%{step: "deploy", environment: ""}, frame)

    assert response_text(response) =~ "needs :environment"
  end

  test "naming an environment gets past the refusal", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} =
             RunProvisioningStep.execute(%{step: "deploy", environment: "uat"}, frame)

    refute response_text(response) =~ "needs :environment"
  end

  test "other steps are unaffected — no environment required", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} = RunProvisioningStep.execute(%{step: "secrets"}, frame)

    refute response_text(response) =~ "needs :environment"
  end
end

defmodule CodeMySpec.Provisioning.Tools.RunProvisioningStepDeployEnvironmentTest do
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

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments

  setup do
    scope = full_scope_fixture()
    {:ok, _} = Environments.put(scope, "prod", %{})
    {:ok, _} = Environments.put(scope, "uat", %{})
    %{scope: scope}
  end

  defp response_text({_status, text}), do: text

  test "refuses a deploy with no environment named, before touching either one", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "run_provisioning_step",
        %{step: "deploy"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    text = response_text(response)
    assert text =~ "needs :environment"
    assert text =~ "never all of them at once"
  end

  test "an empty environment string is refused the same as a missing one", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "run_provisioning_step",
        %{step: "deploy", environment: ""},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert response_text(response) =~ "needs :environment"
  end

  test "naming an environment gets past the refusal", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "run_provisioning_step",
        %{step: "deploy", environment: "uat"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    refute response_text(response) =~ "needs :environment"
  end

  test "other steps are unaffected — no environment required", %{scope: scope} do
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "run_provisioning_step",
        %{step: "secrets"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    refute response_text(response) =~ "needs :environment"
  end
end

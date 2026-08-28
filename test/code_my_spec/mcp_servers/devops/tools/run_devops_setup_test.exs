defmodule CodeMySpec.McpServers.Devops.Tools.RunDevopsSetupTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.RunDevopsSetup
  alias CodeMySpec.Provisioning.StepRepository
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  # Fake providers only, same reasoning as ResourcesTest: this exists to
  # prove the tool's own scoping and outcome reporting, not to exercise real
  # steps. Global config, so async: false.
  setup do
    previous_async = Application.get_env(:code_my_spec, :provisioning_async, true)
    Application.put_env(:code_my_spec, :provisioning_async, true)
    on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_async, previous_async) end)

    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(:code_my_spec, :provisioning_step_opts,
      verify: fn _scope, _key -> {:ok, :absent} end,
      execute: fn _scope, _key, _opts -> {:ok, []} end
    )

    on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # No project_id parameter at all — this used to take one, and separately
    # accepted omitting it as "build every devops-enabled project in the
    # account". Either shape let a caller name (or fail to name) a different
    # project than the one this call is actually connected to. Now there is
    # nothing to pass: it always acts on scope.active_project, the same
    # project Validators.devops_project/1 resolves for every other devops
    # tool.
    test "starts a run for the project this call is connected to", %{
      scope: scope,
      project: project
    } do
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = RunDevopsSetup.execute(%{}, frame)

      assert response.isError == false
      assert response_text(response) =~ project.id
      assert response_text(response) =~ "started"

      # Waited on :done, not on the row existing — a step row is written
      # when the step *starts*, not when it finishes. Also lets the async
      # task started above finish against this test's own sandboxed
      # connection before the test process exits and tears it down —
      # ResourcesTest documents the same requirement for the same reason.
      wait_until(fn -> step_state(scope, :callback_credential) == :done end)
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  defp step_state(scope, step), do: scope |> StepRepository.get(step) |> state_of()

  defp state_of(nil), do: nil
  defp state_of(record), do: record.state

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition never became true")
  defp wait_until(fun, attempts), do: retry_until(fun.(), fun, attempts)

  defp retry_until(true, _fun, _attempts), do: :ok

  defp retry_until(_falsy, fun, attempts) do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end
end

defmodule CodeMySpecWeb.ConsoleAsyncRetryTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpec.Provisioning
  alias CodeMySpec.ProvisioningPlan.StepRepository

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  setup %{scope: scope} do
    previous_async = Application.fetch_env(:code_my_spec, :provisioning_run_async)
    previous_opts = Application.fetch_env(:code_my_spec, :provisioning_step_opts)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :provisioning, :failed],
        &hold_project_failure/4,
        {scope.active_project_id, parent}
      )

    Application.put_env(:code_my_spec, :provisioning_run_async, true)

    Application.put_env(:code_my_spec, :provisioning_step_opts,
      verify: fn _, key ->
        send(parent, {:verified, key})
        {:ok, :absent}
      end,
      execute: fn _, key, _ ->
        send(parent, {:executing, key, self()})

        receive do
          {:finish_step, result} -> result
        after
          5_000 -> {:error, "test did not release execution"}
        end
      end
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      restore_env(:provisioning_run_async, previous_async)
      restore_env(:provisioning_step_opts, previous_opts)
    end)

    :ok
  end

  test "Retry enables after an asynchronous failure and reruns only email on the same view", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    {:ok, repository} =
      Provisioning.run_step(scope, :repository,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ -> {:ok, []} end
      )

    :ok = Provisioning.subscribe(scope)
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/resources/mail")
    email = "[data-test='resource-step'][data-step='email']"

    view |> element(email <> " [data-test='run-step']") |> render_click()
    assert_receive {:verified, :email}
    assert_receive {:executing, :email, worker}, 5_000
    await_element(view, email <> "[data-state='running'] button[disabled]")
    send(worker, {:finish_step, {:error, "Resend rejected the sending domain"}})

    assert_receive {:failure_persisted, ^worker}, 5_000
    await_element(view, email <> "[data-state='errored'] [data-test='retry-step'][disabled]")
    assert Provisioning.runs_in_flight?(scope)
    send(worker, :finish_failure)

    assert_receive {:provisioning, :finished, {:halt, _, "Resend rejected the sending domain"}},
                   5_000

    refute Provisioning.runs_in_flight?(scope)
    await_element(view, email <> " [data-test='retry-step']:not([disabled])")
    view |> element(email <> " [data-test='retry-step']") |> render_click()

    assert_receive {:verified, :email}
    assert_receive {:executing, :email, retry_worker}, 5_000
    send(retry_worker, {:finish_step, {:ok, []}})
    assert_receive {:provisioning, :finished, {:ok, _}}, 5_000
    await_element(view, email <> "[data-state='done'] button:not([disabled])")

    assert StepRepository.get(scope, :repository) == repository
    refute_receive {:verified, _}
    refute_receive {:executing, _, _}
  end

  defp await_element(view, selector, attempts \\ 100)
  defp await_element(view, selector, 0), do: assert(has_element?(view, selector))

  defp await_element(view, selector, attempts) do
    await_element_result(has_element?(view, selector), view, selector, attempts)
  end

  defp await_element_result(true, _view, _selector, _attempts), do: :ok

  defp await_element_result(false, view, selector, attempts) do
    Process.sleep(10)
    await_element(view, selector, attempts - 1)
  end

  defp hold_project_failure(
         _event,
         _measurements,
         %{scope: %{active_project_id: project_id}},
         {project_id, parent}
       ) do
    send(parent, {:failure_persisted, self()})

    receive do
      :finish_failure -> :ok
    after
      5_000 -> raise "test did not release the failed run"
    end
  end

  defp hold_project_failure(_event, _measurements, _metadata, _config), do: :ok

  defp restore_env(key, {:ok, value}), do: Application.put_env(:code_my_spec, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:code_my_spec, key)
end

defmodule CodeMySpecWeb.ConsoleRepositoryAdoptionTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  setup do
    previous_opts = Application.fetch_env(:code_my_spec, :provisioning_step_opts)
    parent = self()

    Application.put_env(:code_my_spec, :provisioning_step_opts,
      verify: fn _, _ -> {:ok, :absent} end,
      execute: fn _, key, opts ->
        send(parent, {:repository_execution, key, opts})
        {:ok, []}
      end
    )

    on_exit(fn -> restore_step_opts(previous_opts) end)

    :ok
  end

  defp restore_step_opts({:ok, value}),
    do: Application.put_env(:code_my_spec, :provisioning_step_opts, value)

  defp restore_step_opts(:error),
    do: Application.delete_env(:code_my_spec, :provisioning_step_opts)

  test "an existing org repository can be named before a collision", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    :ok = CodeMySpec.Provisioning.subscribe(scope)
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/resources/repository")

    view
    |> form("#adopt-repository-form", %{"owner" => "Code-My-Spec", "name" => "metric_flow"})
    |> render_submit()

    assert_receive {:repository_execution, :repository, opts}, 5_000
    assert opts[:owner] == "Code-My-Spec"
    assert opts[:name] == "metric_flow"
    assert opts[:adopt] == true
    assert_receive {:provisioning, :step, %{key: :repository, state: :done}}, 5_000
    assert CodeMySpec.ProvisioningPlan.StepRepository.get(scope, :repository).state == :done
  end

  test "invalid owner or repository input does not run provisioning", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/resources/repository")

    view
    |> form("#adopt-repository-form", %{"owner" => "Code-My-Spec", "name" => "../metric_flow"})
    |> render_submit()

    assert render(view) =~ "Enter a GitHub owner and repository name."
    refute_receive {:repository_execution, _, _}
  end
end

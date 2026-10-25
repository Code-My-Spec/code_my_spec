defmodule CodeMySpec.AppInstances.Tools.AttachedRestartTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.{AppInstances, WorkingCopies}
  alias CodeMySpec.Agents.{Agent, AppRestart}
  alias CodeMySpec.AgentAttachments.Attachment
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.AppInstances.Tools.RestartApp

  test "attached and detached Main route restart and its receipt to the selected copy" do
    scope = working_copy_scope_fixture()
    {:ok, home} = WorkingCopies.fetch(scope.active_working_copy_id)
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/attached-restart-target")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    agent =
      Repo.insert!(%Agent{
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        working_copy_id: home.id,
        working_copy: home.root,
        role: :main,
        provider: "openai",
        status: :running
      })

    Repo.insert!(%Attachment{
      agent_id: agent.id,
      project_id: scope.active_project_id,
      account_id: scope.active_account_id,
      working_copy_id: copy.id
    })

    parent = self()

    harness =
      spawn_link(fn ->
        :ok = HarnessRegistry.register_executor(copy.id, "attached-restart", copy.root)
        send(parent, {:registered, self()})
        serve_restarts(parent, 2)
      end)

    assert_receive {:registered, ^harness}, 2_000

    for caller_scope <- [scope, %{scope | active_working_copy_id: nil}] do
      assert {:ok, text} =
               RestartApp.call(%{instance_id: instance.id}, %{
                 scope: caller_scope,
                 agent_id: agent.id
               })

      assert text =~ "Restarted"
      assert_receive {:restarted, descriptor}
      assert descriptor["instance_id"] == instance.id
      assert descriptor["working_copy_id"] == copy.id
      assert descriptor["root"] == copy.root
    end

    receipts = Repo.all(AppRestart)
    assert length(receipts) == 2
    assert Enum.all?(receipts, &(&1.working_copy_id == copy.id))
    refute Enum.any?(receipts, &(&1.working_copy_id == home.id))
  end

  defp serve_restarts(_parent, 0), do: :ok

  defp serve_restarts(parent, remaining) do
    receive do
      {:"$gen_call", from, {:restart_app, %{instance: descriptor}}} ->
        send(parent, {:restarted, descriptor})

        GenServer.reply(
          from,
          {:ok,
           %{
             instance_id: descriptor["instance_id"],
             status: "serving",
             url: "http://127.0.0.1:12345",
             commit: "current"
           }}
        )

        serve_restarts(parent, remaining - 1)
    end
  end
end

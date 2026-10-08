defmodule CodeMySpec.Agents.AnIssueBoundAgentResumesAfterBlockerReleaseTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    %{scope: full_scope_fixture()}
  end

  test "real blocker release wakes an issue-bound agent and permits task completion twice", %{
    scope: scope
  } do
    for _ <- 1..2 do
      issue = issue_fixture(scope, %{status: :accepted})

      {:ok, copy} =
        CodeMySpec.WorkingCopies.issue(scope, nil,
          device: CodeMySpec.DevicesFixtures.device_fixture(scope)
        )

      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "anthropic",
          role: :coding,
          continuous: true,
          status: :running,
          working_copy: "/tmp/issue-release",
          working_copy_id: copy.id
        })

      AgentPresence.present(agent)
      {:ok, _} = CodeMySpec.Agents.assign_issue_to_working_copy(scope, issue.id, copy.id)
      agent = Repo.reload!(agent)

      {:ok, agent} =
        TaskOwner.add_task(scope, agent, %{
          requirement_name: "fix_issue",
          issue_id: issue.id,
          status: :active
        })

      task = TaskOwner.active_task(agent)
      blocker = Ecto.UUID.generate()
      {:ok, _} = TaskOwner.block_task(scope, agent, task.id, :question, blocker)
      agent_id = agent.id

      log =
        capture_log(fn ->
          assert {:ok, 1} = TaskOwner.blocker_resolved(:question, blocker, :answered)
          assert_receive {:work_turn_requested, ^agent_id, _ref, prompt}, 5_000
          assert prompt =~ task.id

          CodeMySpec.TaskSupervisor
          |> Task.Supervisor.children()
          |> Enum.map(&Process.monitor/1)
          |> Enum.each(fn ref ->
            assert_receive {:DOWN, ^ref, :process, _pid, reason}, 5_000
            assert reason in [:normal, :noproc]
          end)
        end)

      refute log =~ "BadMapError"
      refute log =~ "terminating"
      assert [_ | _] = Offers.list(scope, agent_id: agent_id, kind: :unblocked)
      {:ok, resumed} = TaskOwner.resume_task(scope, Repo.reload!(agent), task.id)
      assert TaskOwner.active_task(resumed).id == task.id
      {:ok, completed} = TaskOwner.complete_task(scope, resumed, task.id)
      assert TaskOwner.find_task(completed, task.id).status == :completed
    end
  end

  test "ID-only lookup respects project and account boundaries and rejects invalid scopes", %{
    scope: scope
  } do
    issue = issue_fixture(scope, %{status: :accepted})
    other = full_scope_fixture()

    minimal = %CodeMySpec.Users.Scope{
      active_account_id: scope.active_account_id,
      active_project_id: scope.active_project_id
    }

    assert %{id: id} = Issues.get_issue(minimal, issue.id)
    assert id == issue.id

    assert Issues.get_issue(%{minimal | active_project_id: other.active_project_id}, issue.id) ==
             nil

    assert Issues.get_issue(%{minimal | active_account_id: other.active_account_id}, issue.id) ==
             nil

    for project_id <- [nil, "invalid", Ecto.UUID.generate()] do
      assert Issues.get_issue(%{minimal | active_project_id: project_id}, issue.id) == nil
    end

    for account_id <- [nil, "invalid", Ecto.UUID.generate()] do
      assert Issues.get_issue(%{minimal | active_account_id: account_id}, issue.id) == nil
    end

    assert {:ok, %{id: ^id}} = Issues.fetch_issue(minimal, String.slice(issue.id, 0, 8))
  end

  test "ID-only vendor scopes retain framework access without exposing tenant app issues", %{
    scope: scope
  } do
    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    Application.put_env(:code_my_spec, :code_my_spec_project_id, scope.active_project_id)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:code_my_spec, :code_my_spec_project_id),
        else: Application.put_env(:code_my_spec, :code_my_spec_project_id, previous)
    end)

    tenant = full_scope_fixture()
    framework = issue_fixture(tenant, %{scope: :framework})
    app = issue_fixture(tenant, %{scope: :app})

    vendor = %CodeMySpec.Users.Scope{
      active_account_id: scope.active_account_id,
      active_project_id: scope.active_project_id
    }

    assert Issues.get_issue(vendor, framework.id).id == framework.id
    assert Issues.get_issue(vendor, app.id) == nil

    assert Issues.get_issue(%{vendor | active_account_id: tenant.active_account_id}, framework.id) ==
             nil
  end
end

defmodule CodeMySpec.EpicsTest do
  @moduledoc """
  Issue b6462c09: `work_dispatched` called a project idle while two agents
  held claimed tasks, and called three already-shipped stories ready to
  assign because nothing excluded a promoted story from the epicless-ready
  set.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Epics
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Task

  describe "dispatch_state/1" do
    test "an agent holding a claimed task is in progress, with no epic dispatched" do
      scope = full_scope_fixture()
      story_fixture(scope)

      %Agent{
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        provider: "anthropic",
        working_copy: "/tmp/epics-test",
        tasks: [%Task{id: Ecto.UUID.generate(), status: :active}]
      }
      |> Repo.insert!()

      assert {:nothing_to_assign, :in_progress} = Epics.dispatch_state(scope)
    end

    test "a task that is not active does not count as in progress" do
      scope = full_scope_fixture()
      story_fixture(scope)

      %Agent{
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        provider: "anthropic",
        working_copy: "/tmp/epics-test",
        tasks: [%Task{id: Ecto.UUID.generate(), status: :completed}]
      }
      |> Repo.insert!()

      assert {:work_to_assign, _} = Epics.dispatch_state(scope)
    end

    test "a promoted story is not offered for dispatch" do
      scope = full_scope_fixture()
      story_fixture(scope, %{promoted_version: "1.2.3"})

      assert {:nothing_to_assign, :all_assigned} = Epics.dispatch_state(scope)
    end

    test "an unpromoted ready story with no epic is work to assign" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:work_to_assign, %{ready: [found], fixes: []}} = Epics.dispatch_state(scope)
      assert found.id == story.id
    end
  end

  # Legacy promotion stamped 117 CodeMySpec stories while 190 accepted issues
  # sat on them, most in draft epics; with promoted stories filtered out,
  # nothing ever put them in front of a team (2026-10-17).
  describe "dispatch_state/1 with accepted fixes" do
    setup do
      scope = full_scope_fixture()

      {:ok, epic} =
        Epics.create_epic(scope, %{name: "an epic", slug: "an-epic", description: "d"})

      %{scope: scope, epic: epic}
    end

    test "a shipped story in a draft epic, not ready, with an accepted fix is work", %{
      scope: scope,
      epic: epic
    } do
      story =
        story_fixture(scope, %{promoted_version: "2.0.11", ready_for_dev: false, epic_id: epic.id})

      accepted_fix(scope, story, :medium)

      assert {:work_to_assign, %{fixes: [found], ready: []}} = Epics.dispatch_state(scope)
      assert found.id == story.id
    end

    test "a fix below the project's threshold is not work", %{scope: scope} do
      story = story_fixture(scope, %{promoted_version: "2.0.11"})
      accepted_fix(scope, story, :low)

      assert {:nothing_to_assign, :all_assigned} = Epics.dispatch_state(scope)
    end

    test "an incoming issue is not work until it is accepted", %{scope: scope} do
      story = story_fixture(scope, %{promoted_version: "2.0.11"})
      issue_fixture(scope, %{story_id: story.id, severity: :high})

      assert {:nothing_to_assign, :all_assigned} = Epics.dispatch_state(scope)
    end

    test "a fix already on a copy, or a story a copy holds, is that team's", %{scope: scope} do
      copy = copy_fixture(scope)
      on_copy = story_fixture(scope, %{promoted_version: "2.0.11"})
      scope |> accepted_fix(on_copy, :high) |> set(assigned_working_copy_id: copy.id)
      held = story_fixture(scope, %{promoted_version: "2.0.11"})
      accepted_fix(scope, held, :high)
      set(held, working_copy_id: copy.id)

      assert {:nothing_to_assign, :all_assigned} = Epics.dispatch_state(scope)
    end

    test "fixes come worst severity first, and a ready story with a fix is a fix", %{scope: scope} do
      medium = story_fixture(scope, %{promoted_version: "2.0.11"})
      accepted_fix(scope, medium, :medium)
      critical = story_fixture(scope, %{promoted_version: "2.0.11"})
      accepted_fix(scope, critical, :critical)
      ready = story_fixture(scope)
      accepted_fix(scope, ready, :high)

      assert {:work_to_assign, %{fixes: fixes, ready: []}} = Epics.dispatch_state(scope)
      assert Enum.map(fixes, & &1.id) == [critical.id, ready.id, medium.id]
    end
  end

  defp accepted_fix(scope, story, severity) do
    issue = issue_fixture(scope, %{story_id: story.id, severity: severity})
    {:ok, issue} = CodeMySpec.Issues.accept_issue(scope, issue)
    issue
  end

  defp set(%struct{id: id} = row, fields) do
    {1, _} = Repo.update_all(from(r in struct, where: r.id == ^id), set: fields)
    row
  end

  defp copy_fixture(scope) do
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    copy
  end
end

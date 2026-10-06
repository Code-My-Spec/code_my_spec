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

      assert {:work_to_assign, [found]} = Epics.dispatch_state(scope)
      assert found.id == story.id
    end
  end
end

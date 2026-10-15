defmodule CodeMySpec.McpServers.Stories.Tools.SyncWorkingCopyTest do
  @moduledoc """
  8f5ebfb2: nothing reachable could bring a stale working copy's checkout
  up to date before staffing it. These drive execute/2 the way an agent's
  call does; the fs_request round trip itself is faked the same way
  Promotion.AConflictReportedByTheHarnessIsReadTest fakes it, since both
  go through Analysis.harness_fs_request/4 by the same contract.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.McpServers.Stories.Tools.SyncWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = %{scope | active_project_id: project.id}

    copy_id = WorkingCopies.ensure_default(scope)
    {:ok, copy} = WorkingCopies.fetch(copy_id)

    %{scope: scope, copy: copy}
  end

  defp frame_for(scope), do: %Frame{assigns: %{current_scope: scope}}

  defp fakes_fs_request(copy_id, reply) do
    test = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(HarnessRegistry, copy_id, :test)
      send(test, :up)

      receive do
        {:"$gen_call", from, {:fs_request, "sync_to_main", %{}}} ->
          GenServer.reply(from, reply)
      end
    end)

    assert_receive :up
  end

  test "no working copy has that id", %{scope: scope} do
    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: Ecto.UUID.generate()}, frame_for(scope))

    assert response.isError
    assert text_of(response) =~ "No working copy has the id"
  end

  test "a working copy belonging to a different project is refused", %{scope: scope} do
    other_scope = %{scope | active_project_id: Ecto.UUID.generate()}
    other_copy_id = WorkingCopies.ensure_default(%{scope | active_project_id: project_fixture(other_scope).id})

    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: other_copy_id}, frame_for(scope))

    assert response.isError
    assert text_of(response) =~ "a different project"
  end

  test "a harness that already fast-forwarded reports the new commit", %{
    scope: scope,
    copy: copy
  } do
    fakes_fs_request(copy.id, {:ok, %{"from" => "abc111", "to" => "def222", "updated" => true}})

    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: copy.id}, frame_for(scope))

    refute response.isError
    assert text_of(response) =~ "def222"
    assert text_of(response) =~ "abc111"
  end

  test "already at main's HEAD is reported plainly, not as a failure", %{
    scope: scope,
    copy: copy
  } do
    fakes_fs_request(copy.id, {:ok, %{"from" => "abc111", "to" => "abc111", "updated" => false}})

    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: copy.id}, frame_for(scope))

    refute response.isError
    assert text_of(response) =~ "already at main's HEAD"
  end

  test "a dirty tree refuses, naming the reason", %{scope: scope, copy: copy} do
    fakes_fs_request(
      copy.id,
      {:error, %{"tag" => "dirty_tree", "detail" => "this checkout has uncommitted changes"}}
    )

    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: copy.id}, frame_for(scope))

    assert response.isError
    assert text_of(response) =~ "uncommitted changes"
  end

  test "a non-fast-forward refuses rather than merging", %{scope: scope, copy: copy} do
    fakes_fs_request(
      copy.id,
      {:error, %{"tag" => "not_fast_forward", "detail" => "git exited 1: not possible"}}
    )

    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: copy.id}, frame_for(scope))

    assert response.isError
    assert text_of(response) =~ "would not be a fast-forward"
  end

  test "a harness that is not connected says so", %{scope: scope, copy: copy} do
    assert {:reply, response, _frame} =
             SyncWorkingCopy.execute(%{working_copy_id: copy.id}, frame_for(scope))

    assert response.isError
    assert text_of(response) =~ "not connected"
  end

  defp text_of(%{content: [%{"text" => text} | _]}), do: text
end

defmodule CodeMySpec.McpServers.AssignEpicToWorkingCopyTest do
  @moduledoc """
  Placing an epic is its own act.

  John's call on 8062ccba, against a design where approving an epic did
  everything at once: *"I think for the time being we should keep this flexible
  so let's have these as separate actions — creating the working copy and
  assigning an epic to a working copy ... the user should be able to decide where
  to assign it or the agent should be able to decide."*

  Neither could before this. There was no agent-facing way to see a project's
  checkouts or to place an epic on one, so "an appropriate working copy" was not
  a judgement anything was able to make.

  Driven through the context rather than the MCP frame: what these assert is the
  placement rule, and the tool is a thin `with` over it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, epic} = Epics.create_epic(scope, %{name: "Placeable work"})
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    %{scope: scope, epic: epic, copy: copy}
  end

  defp rooted(copy, root) do
    copy |> Ecto.Changeset.change(root: root) |> CodeMySpec.Repo.update!()
  end

  test "an epic can be placed on a rooted checkout without being approved first", %{
    scope: scope,
    epic: epic,
    copy: copy
  } do
    copy = rooted(copy, "/workspace/app")

    assert {:ok, placed} = Epics.update_epic(scope, epic, %{working_copy_id: copy.id})

    assert placed.working_copy_id == copy.id

    assert placed.status == :draft,
           "placing changed the epic's status. Approval and placement are separate acts " <>
             "on purpose, and a placement that silently approves takes the agreement out " <>
             "of the user's hands."
  end

  test "placement does not start anything", %{scope: scope, epic: epic, copy: copy} do
    copy = rooted(copy, "/workspace/app")
    {:ok, _} = Epics.update_epic(scope, epic, %{working_copy_id: copy.id})

    assert CodeMySpec.Agents.list_running(scope) == [],
           "assigning started an agent. That is a third act, and bundling it in is what " <>
             "the flexible split exists to avoid — a copy may already have one working."
  end

  test "a rootless copy is refused, through the tool", %{scope: scope, epic: epic, copy: copy} do
    # The nil-object row `ensure_default/1` mints. It exists, which is exactly
    # why it is pickable by mistake — issue 28e838cc is that mistake made by
    # code, an epic reporting it was being built on a directory that is not
    # there.
    copy = rooted(copy, nil)
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:reply, response, ^frame} =
             AssignEpicToWorkingCopy.execute(
               %{epic_id: epic.id, working_copy_id: copy.id},
               frame
             )

    assert rendered(response) =~ "no checkout on disk",
           "the refusal has to name what is wrong with the choice, or the caller " <>
             "picks the same row again. Got: #{rendered(response)}"

    assert CodeMySpec.Repo.reload!(epic).working_copy_id == nil,
           "refused and wrote anyway."
  end

  defp rendered(response), do: inspect(response)
end

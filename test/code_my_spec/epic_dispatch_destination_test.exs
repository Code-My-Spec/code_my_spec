defmodule CodeMySpec.EpicDispatchDestinationTest do
  @moduledoc """
  An epic is only "being built on" a checkout that exists.

  Issue 28e838cc. Approving an epic on a project with no designated checkout
  dispatched it to the nil-object row `ensure_default/1` mints — `root IS NULL`,
  no disk behind it — and the page then said "Being built on your project's
  checkout" about a directory that does not exist.

  Story 963's defect in a second place: there, a rootless copy became a project's
  main one and an agent was started on nowhere, reported forever as "Getting
  ready". The rule that fixed it is that a row is not a checkout until it reports
  a root, and this is that rule applied here.

  `destination/1` already does the right thing. Nothing checked it, which is the
  issue's own complaint about the twelve spex that pass this story: they assert
  the marker renders, and it does — saying something untrue.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, epic} = Epics.create_epic(scope, %{name: "Ready work"})
    {:ok, epic} = EpicDispatch.propose(scope, epic.id)
    %{scope: scope, epic: epic}
  end

  defp rooted?(scope) do
    case WorkingCopies.main(scope) do
      %{root: root} -> is_binary(root) and root != ""
      _ -> false
    end
  end

  test "with no rooted checkout, the epic is dispatched and goes nowhere", %{
    scope: scope,
    epic: epic
  } do
    # The issue's actual case, and it is not "no main copy at all" — that one
    # passes whatever `destination/1` does. `ensure_default/1` mints a row with
    # `root IS NULL` for a writer who has no checkout, and *that* row became the
    # project's main one and then the epic's destination.
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    copy
    |> Ecto.Changeset.change(root: nil, main: true)
    |> CodeMySpec.Repo.update!()

    refute rooted?(scope), "this test's premise is a main copy with nothing behind it"

    assert {:ok, dispatched} = EpicDispatch.approve(scope, epic.id)

    assert dispatched.status == :dispatched,
           "the user agreed and that stands — an epic with nowhere to go is dispatched " <>
             "and waiting, not refused."

    assert dispatched.working_copy_id == nil,
           "the epic was pointed at a working copy on a project that has no checkout. " <>
             "That is how the page came to claim it was being built on the project's " <>
             "checkout, about a directory that does not exist — and the branch written " <>
             "for exactly this case keys on nil, so a non-nil id makes it unreachable."
  end

  test "a rooted main checkout does receive it", %{scope: scope, epic: epic} do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    copy
    |> Ecto.Changeset.change(root: "/workspace/app", main: true)
    |> CodeMySpec.Repo.update!()

    assert {:ok, dispatched} = EpicDispatch.approve(scope, epic.id)

    assert dispatched.working_copy_id == copy.id,
           "guarding the rootless case must not stop work reaching a real checkout, " <>
             "which is the whole story."
  end
end

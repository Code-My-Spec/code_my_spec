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

  ## Where the placement is now read

  On the epic's **stories**, not on the epic. Story 895 moved the binding down a
  level, because an epic has no place in the requirement graph and a copy
  recorded on one was never consulted when deciding what an agent is offered.

  So these tests give their epic a story. That is not scaffolding: placement is a
  story-level fact now, and an epic with no stories has nothing to place —
  asserting against an empty epic would pass whatever `dispatch/2` did.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, epic} = Epics.create_epic(scope, %{name: "Ready work"})
    story = story_fixture(scope, %{epic_id: epic.id})
    {:ok, epic} = EpicDispatch.propose(scope, epic.id)
    %{scope: scope, epic: epic, story: story}
  end

  # Where the epic's work actually went, read off its stories.
  defp placement(story), do: Repo.get!(Story, story.id).working_copy_id

  defp rooted?(scope) do
    scope
    |> WorkingCopies.main()
    |> has_root?()
  end

  defp has_root?(%{root: root}), do: is_binary(root) and root != ""
  defp has_root?(_other), do: false

  test "with no rooted checkout, the epic is dispatched and goes nowhere", %{
    scope: scope,
    epic: epic,
    story: story
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

    assert placement(story) == nil,
           "the epic's story was pointed at a working copy on a project that has no " <>
             "checkout. That is how the page came to claim it was being built on the " <>
             "project's checkout, about a directory that does not exist — and the branch " <>
             "written for exactly this case keys on nil, so a non-nil id makes it " <>
             "unreachable."
  end

  # The intent is unchanged and the destination is not.
  #
  # This asserted the epic landed on the *main* checkout. It cannot now: the
  # main copy holds exactly one agent and it is the project's own
  # (`Agents.main_copy_is_free/2`), so an epic placed there could never be
  # staffed — every roster start was refused, which is what kept story 964's
  # criteria red. John, 2026-09-04: "the main copy just gets the main agent, and
  # we would create a working copy to do the actual work on."
  #
  # So work still has to reach a real checkout, which is what this test is for.
  # It reaches one made for it.
  test "a rooted machine means the work reaches a real checkout", %{
    scope: scope,
    epic: epic,
    story: story
  } do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    copy
    |> Ecto.Changeset.change(root: "/workspace/app", main: true)
    |> CodeMySpec.Repo.update!()

    assert {:ok, dispatched} = EpicDispatch.approve(scope, epic.id)
    assert dispatched.status == :dispatched

    landed = placement(story)

    assert landed,
           "guarding the rootless case must not stop work reaching a real checkout, " <>
             "which is the whole story. The epic's story carries the placement now — " <>
             "an epic that records nothing is one its agents will never be offered."

    refute landed == copy.id,
           "the work went to the main checkout, where a roster cannot be started. " <>
             "A copy that cannot hold the agents the work needs is not somewhere " <>
             "the work can happen."

    {:ok, destination} = WorkingCopies.fetch(landed)

    assert is_binary(destination.root) and destination.root != "",
           "the epic was pointed at a row with no checkout behind it, which is the " <>
             "defect this whole file exists to guard."
  end
end

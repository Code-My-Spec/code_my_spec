defmodule CodeMySpec.AcceptanceCriteria.NewCriterionRestartsTheSpecsChainTest do
  @moduledoc """
  A criterion that did not exist has never been green.

  `specs_ready` is the latch the spex gate reads. `Validation`'s
  `split_by_story_enforcement/3` only lets a red spex block on a story where it
  is true, and states the reasoning plainly:

  > A spex that reaches here is red on a story that was green once, which is a
  > regression in this working copy, not somebody else's in-flight work.

  That holds for a story whose criteria all went green together. It breaks the
  moment one is added afterwards. The story *was* green once, so the latch stays
  set — and every red spex for the new criterion enforces, project-wide, for
  every session.

  Issue 10e86fa2 is that, observed: a session writing seven criteria
  red-then-green on purpose blocked an unrelated session on a different story.
  The stop hook re-fired the same block on every attempt, with no way to record
  a human's "ignore this one" and no action available that would change the
  answer.

  The latch is per story and the red is per criterion. Closing that gap exactly
  means recording green per criterion; this closes it by restarting the story,
  which is the same move `Story.clear_specs_ready_on_readiness_change/1` already
  makes when a story is released or parked — a latch earned on the previous pass
  says nothing about this one.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Stories

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  defp latched_story(scope, attrs \\ %{}) do
    scope
    |> story_fixture(Map.merge(%{title: "A story that went green"}, attrs))
    |> then(&latch!(scope, &1))
  end

  # Re-read before setting. `update_story/3` casts onto the struct it is handed,
  # so setting `specs_ready: true` on a *stale* struct that already reads true
  # produces no change and writes nothing — leaving the row false while the test
  # believes it re-latched. Caught here by two tests failing for a reason that
  # had nothing to do with the code under test.
  defp latch!(scope, story) do
    fresh = Stories.get_story(scope, story.id)
    {:ok, latched} = Stories.set_specs_ready(scope, fresh, true)
    latched
  end

  defp specs_ready?(scope, story) do
    Stories.get_story(scope, story.id).specs_ready
  end

  describe "adding a criterion to a latched story" do
    test "clears the latch", %{scope: scope} do
      story = latched_story(scope)

      {:ok, _criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{
          description: "A criterion nobody has written a spex for yet"
        })

      refute specs_ready?(scope, story),
             "the story kept a latch it earned before this criterion existed, so " <>
               "the red spex about to be written for it will block every session " <>
               "in the project as though it were a regression."
    end

    test "a story with no latch stays unlatched", %{scope: scope} do
      story = story_fixture(scope, %{title: "Never been green"})

      {:ok, _} = AcceptanceCriteria.create_criterion(scope, story, %{description: "First one"})

      refute specs_ready?(scope, story)
    end

    test "each of several criteria leaves it clear", %{scope: scope} do
      story = latched_story(scope)

      for n <- 1..3 do
        {:ok, _} = AcceptanceCriteria.create_criterion(scope, story, %{description: "C#{n}"})
      end

      refute specs_ready?(scope, story)
    end
  end

  describe "what the restart must not touch" do
    test "a different story's latch is left alone", %{scope: scope} do
      target = latched_story(scope, %{title: "Getting a new criterion"})
      bystander = latched_story(scope, %{title: "Minding its own business"})

      {:ok, _} = AcceptanceCriteria.create_criterion(scope, target, %{description: "New"})

      assert specs_ready?(scope, bystander),
             "clearing a latch on an unrelated story turns one session's work into " <>
               "every other story's spex going quiet."
    end

    test "editing a criterion's wording does not restart the chain", %{scope: scope} do
      story = latched_story(scope)
      {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, %{description: "One"})
      story = latch!(scope, story)

      {:ok, _} = AcceptanceCriteria.update_criterion(scope, criterion, %{description: "One, but clearer"})

      assert specs_ready?(scope, story),
             "a reworded criterion is the same criterion. Restarting on every edit " <>
               "would mean a story is never enforceable for long enough to catch " <>
               "anything."
    end
  end

  describe "moving a criterion between stories" do
    test "the destination restarts", %{scope: scope} do
      source = story_fixture(scope, %{title: "Where it came from"})
      destination = latched_story(scope, %{title: "Where it is going"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, source, %{description: "Portable"})

      {:ok, _} =
        AcceptanceCriteria.update_criterion(scope, criterion, %{story_id: destination.id})

      refute specs_ready?(scope, destination),
             "moving a criterion in adds one to the destination, which has never " <>
               "been green with it."
    end

    test "the story it left keeps its latch", %{scope: scope} do
      source = latched_story(scope, %{title: "Where it came from"})
      destination = story_fixture(scope, %{title: "Where it is going"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, source, %{description: "Portable"})

      source = latch!(scope, source)

      {:ok, _} =
        AcceptanceCriteria.update_criterion(scope, criterion, %{story_id: destination.id})

      assert specs_ready?(scope, source),
             "losing a criterion cannot make the remaining ones less green."
    end
  end
end

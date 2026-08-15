defmodule CodeMySpec.Stories.StoryLengthTest do
  @moduledoc """
  The story field holds the sentence; `notes` holds everything else.

  `19665f75`: agents were writing prose into `description` from every entry
  point — story interviews, Three Amigos, the architect, ad-hoc `create_story`
  callers — so list views were unreadable and `get_story` output hard to scan.
  `notes` already existed for that content and nothing steered anyone to it.

  The property that needs a test is not the cap. It is that the cap does **not**
  fire on the 18 existing stories that already exceed it — a validation that
  rejects an unrelated edit to a legacy row turns a tidiness fix into a gate
  that blocks work, and the report explicitly asked for existing rows to be
  grandfathered rather than backfilled.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story

  @sentence "As a developer, I want short stories so that lists stay readable"

  setup do
    %{scope: full_scope_fixture()}
  end

  defp changeset(attrs) do
    Story.changeset(%Story{}, Map.merge(%{title: "T", story: @sentence}, attrs))
  end

  describe "title" do
    test "accepts the longest title on this project today" do
      # Measured: 141 stories, longest title 97 characters. The cap is set to
      # stop drift, not to reject anything that exists.
      assert changeset(%{title: String.duplicate("a", 97)}).valid?
    end

    test "rejects a title being used as a summary" do
      cs = changeset(%{title: String.duplicate("a", 121)})

      refute cs.valid?

      assert "is too long (max 120 characters) — a title is a name, not a summary" in errors_on(
               cs
             ).title
    end
  end

  describe "story" do
    test "rejects prose and says where it goes" do
      cs = changeset(%{story: String.duplicate("a", 601)})

      refute cs.valid?
      [message] = errors_on(cs).story

      assert message =~ "max 600 characters"

      assert message =~ "`notes`",
             "an agent told only that its input is too long will trim the sentence " <>
               "rather than move the prose, which loses the content the report " <>
               "wants preserved"
    end

    # `sync_story_and_description/1` copies whichever arrives into the other, so
    # a cap on one field alone would let the same text in through the other door.
    test "rejects the same prose arriving as description" do
      cs = changeset(%{story: nil, description: String.duplicate("a", 601)})

      refute cs.valid?
      assert errors_on(cs)[:description] || errors_on(cs)[:story]
    end

    test "does not cap notes, which is what the prose is for" do
      assert changeset(%{notes: String.duplicate("a", 5_000)}).valid?
    end
  end

  # The part that matters. 18 of 141 stories already exceed the cap; if editing
  # any unrelated field on one of them failed, this would be a gate rather than
  # a nudge.
  describe "existing over-cap stories" do
    setup %{scope: scope} do
      {:ok, story} =
        Stories.create_story(scope, %{title: "Legacy", story: @sentence})

      # Past the cap, the way these rows actually got there — before it existed.
      {1, _} =
        Repo.update_all(
          from(s in Story, where: s.id == ^story.id),
          set: [story: String.duplicate("a", 900), description: String.duplicate("a", 900)]
        )

      %{story: Repo.reload!(story)}
    end

    test "an unrelated edit still succeeds", %{scope: scope, story: story} do
      assert {:ok, updated} = Stories.update_story(scope, story, %{ready_for_dev: true})
      assert updated.ready_for_dev
      assert String.length(updated.story) == 900, "the legacy text was left alone"
    end

    test "rewriting the sentence is where the cap applies", %{scope: scope, story: story} do
      assert {:error, changeset} =
               Stories.update_story(scope, story, %{story: String.duplicate("b", 700)})

      assert errors_on(changeset).story != []
    end

    test "and a rewrite within the cap is accepted", %{scope: scope, story: story} do
      assert {:ok, updated} = Stories.update_story(scope, story, %{story: @sentence})
      assert updated.story == @sentence
    end
  end
end

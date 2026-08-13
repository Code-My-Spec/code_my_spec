defmodule CodeMySpec.StoriesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Stories` context.
  """

  @doc """
  Generate a story.
  """
  def story_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        criteria: [%{description: "option1"}, %{description: "option2"}],
        description: "some description",
        lock_expires_at: ~U[2025-07-17 12:48:00Z],
        locked_at: ~U[2025-07-17 12:48:00Z],
        priority: 42,
        # A fixture story represents work already in flight, so it is released
        # for development. New stories created through the app start parked —
        # pass `ready_for_dev: false` explicitly to exercise the pace gate.
        ready_for_dev: true,
        # Random ASCII-only word — names with apostrophes (e.g. "O'Kon") get
        # HTML-escaped to `&#39;`, breaking `assert html =~ story.title` in
        # tests that exercise the rendered page.
        title: "Story #{random_word()} #{System.unique_integer([:positive])}"
      })

    {:ok, story} = CodeMySpec.Stories.create_story(scope, attrs)
    story
  end

  @doc "A random lowercase ASCII word, for unique test titles."
  def random_word(length \\ 8) do
    for _ <- 1..length, into: "", do: <<Enum.random(?a..?z)>>
  end
end

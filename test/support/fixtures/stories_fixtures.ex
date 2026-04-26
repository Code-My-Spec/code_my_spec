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
        status: :in_progress,
        # Faker.Person names like "O'Kon" contain apostrophes that the LiveView
        # HTML-escapes to `&#39;`, breaking `assert html =~ story.title` in
        # tests that exercise the rendered page. Lorem words are ASCII-only.
        title: "Story #{Faker.Lorem.word()} #{System.unique_integer([:positive])}"
      })

    {:ok, story} = CodeMySpec.Stories.create_story(scope, attrs)
    story
  end
end

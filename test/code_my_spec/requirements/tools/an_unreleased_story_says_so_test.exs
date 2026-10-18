defmodule CodeMySpec.Requirements.Tools.AnUnreleasedStorySaysSoTest do
  @moduledoc """
  Issue e13b8ccc. Only a story released for development (`ready_for_dev ==
  true`) projects into the requirements graph — `Preloader` filters on it
  (`requirements/preloader.ex:269`), and that is working as designed.

  What is not designed is the answer an agent gets when it asks about one that
  has not been released. `show_story_requirements` renders the row set it
  found, so an unreleased story reads "**Requirements:** 0/0 satisfied" — the
  same text a story with a genuinely missing subgraph would produce. Two
  agents read that as a framework bug and spent a session on it (1086, 1087),
  because nothing in the answer says the story has not been released.

  The fix is a sentence, not a graph change: name the unreleased status rather
  than reporting an empty list as though it were an answer about the work.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "an unreleased story is named as unreleased rather than reported as an empty list" do
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

      # Parked, which is how a story created through the app starts. Released
      # for development is the fixture's default, so it is passed explicitly.
      story = story_fixture(scope, %{ready_for_dev: false})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "show_story_requirements",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)

      assert content =~ "# #{story.title}",
             "the story is still named, got:\n#{content}"

      assert content =~ "not been released",
             "an unreleased story says so, rather than reporting 0/0 as an " <>
               "answer about the work; got:\n#{content}"

      assert content =~ "ready_for_dev",
             "the sentence names the fact that decides it, so the reader has " <>
               "something to act on; got:\n#{content}"
    end

    test "a released story is not told it is unreleased" do
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

      story = story_fixture(scope, %{ready_for_dev: true})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "show_story_requirements",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      content = response_text(response)

      refute content =~ "not been released",
             "a released story must not carry the unreleased note; got:\n#{content}"

      assert content =~ ~r/\*\*Requirements:\*\*\s+\d+\/\d+\s+satisfied/
    end

    test "an unknown story is still a not-found error" do
      scope = CodeMySpec.ConfigurationsFixtures.ensure_configuration!(full_scope_fixture())

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "show_story_requirements",
          %{story_number: 987_654_321},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert response_text(response) =~ "not found"
    end
  end

  defp response_text({_status, text}) when is_binary(text), do: text

  defp response_text({_status, text}), do: text
end

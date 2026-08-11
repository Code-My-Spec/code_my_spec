defmodule CodeMySpec.Files.SpexOwnershipTest do
  @moduledoc """
  Which story a spex file belongs to.

  It used to be the number in the directory name, which is a per-deployment
  story id — so a migrated project's directories all name stories that have
  different ids there. The parse then finds nothing, `bdd_specs_exist` reads as
  work not done, and where a number happens to collide the file binds to
  whichever story owns it now.

  Both halves are covered here: that a recorded path wins, and that a colliding
  directory name does not get to speak over it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel

  defp entry(path), do: %{path: path, role: :bdd_spec}

  describe "a spex file whose criterion recorded it" do
    test "belongs to that criterion's story, whatever the directory says" do
      path = "test/spex/990_guided_intake/criterion_8209_a_visitor_describes_an_idea_spex.exs"

      read_model = %ReadModel{
        story_ids: MapSet.new([875, 990]),
        story_by_spec_path: %{path => 875}
      }

      [resolved] = Scanner.resolve_owners([entry(path)], read_model)

      assert resolved.story_id == 875,
             "the directory says 990 because that is the id the story had on the " <>
               "harness it was migrated from; the criterion says 875, and the " <>
               "criterion is the one that knows"
    end

    test "a directory naming a real but different story does not win" do
      path = "test/spex/810_orchestrator_dispatches_follow_ups/criterion_6529_probe_spex.exs"

      read_model = %ReadModel{
        # 810 exists here — as an entirely different story. That is what made
        # this dangerous rather than merely broken: the parse succeeded.
        story_ids: MapSet.new([810, 975]),
        story_by_spec_path: %{path => 975}
      }

      [resolved] = Scanner.resolve_owners([entry(path)], read_model)

      assert resolved.story_id == 975,
             "an id collision bound subagent-dispatch spex to a story about OAuth " <>
               "registration, and the graph reported it as covered"
    end
  end

  describe "a spex file nothing has recorded" do
    test "still resolves from its path, through the number the directory names" do
      path = "test/spex/42_user_auth/criterion_7_valid_credentials_spex.exs"

      # 42 is the story's durable *number*; 875 is its primary key. The
      # directory has never named the key, and resolving through the map is
      # what keeps those two facts from being confused for one another.
      read_model = %ReadModel{story_ids_by_number: %{42 => 875}, story_by_spec_path: %{}}

      [resolved] = Scanner.resolve_owners([entry(path)], read_model)

      assert resolved.story_id == 875,
             "a spex written moments ago has no recorded path yet, and the parse " <>
               "is the only thing that can place it"
    end

    test "a path naming no story here stays unowned" do
      path = "test/spex/9999_gone/criterion_1_whatever_spex.exs"

      read_model = %ReadModel{story_ids_by_number: %{42 => 875}, story_by_spec_path: %{}}

      [resolved] = Scanner.resolve_owners([entry(path)], read_model)

      assert is_nil(resolved.story_id)
    end

    test "a directory number that happens to equal some story's id owns nothing" do
      # The whole reason this goes through a map. 875 is a real primary key
      # here, and it used to be enough for the parse to succeed: the file was
      # bound to whichever story held that id, silently and wrongly.
      path = "test/spex/875_coincidence/criterion_1_whatever_spex.exs"

      read_model = %ReadModel{
        story_ids: MapSet.new([875]),
        story_ids_by_number: %{42 => 875},
        story_by_spec_path: %{}
      }

      [resolved] = Scanner.resolve_owners([entry(path)], read_model)

      assert is_nil(resolved.story_id),
             "no story is numbered 875, so nothing here owns this file"
    end
  end

  describe "the read model" do
    test "indexes every criterion that records a path", %{} do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, criterion} =
        CodeMySpec.AcceptanceCriteria.create_criterion(scope, story, %{
          description: "a thing happens",
          spec_path: "test/spex/1_x/criterion_1_a_thing_happens_spex.exs"
        })

      index = CodeMySpec.Files.read_model(scope).story_by_spec_path

      assert Map.get(index, criterion.spec_path) == story.id
    end
  end
end

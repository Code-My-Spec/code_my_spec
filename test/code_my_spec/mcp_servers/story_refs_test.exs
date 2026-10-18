defmodule CodeMySpec.Stories.StoryRefsTest do
  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.Requirements.Directives
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp story_node(entity_id) do
    %{
      name: "bdd_specs_exist",
      description: "BDD spec files exist for story",
      satisfied: false,
      execution_type: :sub_agent,
      validation_type: :automatic,
      entity_type: "story",
      entity_id: entity_id,
      entity_name: "A story",
      satisfied_by: WriteBddSpecs,
      orchestrated_by: nil,
      parent_entity_id: nil,
      parent_entity_name: nil,
      role: :bdd
    }
  end

  # A copy with no active story is offered work from every story it holds, so
  # there is no `story` on the execution to take numbers from. What it prints
  # is what an agent hands `start_task`, which reads it as a number.
  describe "an offer across several stories" do
    test "names each story by a number that resolves back to that story" do
      scope = full_scope_fixture()
      stories = for _ <- 1..3, do: story_fixture(scope)

      assert Enum.any?(stories, &(&1.id != &1.number)),
             "the stories need ids that differ from their numbers"

      # The projection carries integer ids and the rows carry text.
      [a, b, c] = stories
      nodes = [story_node(a.id), story_node(to_string(b.id)), story_node(c.id)]

      text =
        Directives.format_story_execution(
          CodeMySpec.Requirements.Directives.number_execution(scope, %{
            status: :ready,
            story: nil,
            actionable: nodes,
            wave: nodes,
            remaining: 0,
            blockers: [],
            reason: ""
          })
        )

      offered =
        ~r/entity_type=`story`, entity_id=`([^`]+)`/
        |> Regex.scan(text)
        |> Enum.map(fn [_, ref] -> ref end)

      assert length(offered) == 3, text

      assert Enum.map(offered, &Stories.get_story_by_number(scope, &1).id) ==
               Enum.map(stories, & &1.id),
             text
    end
  end

  test "a story node that was never numbered is refused rather than named by its id" do
    assert_raise ArgumentError, fn ->
      CodeMySpec.Requirements.Directives.entity_ref(story_node(823))
    end
  end
end

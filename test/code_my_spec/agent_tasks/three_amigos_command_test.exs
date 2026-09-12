defmodule CodeMySpec.AgentTasks.ThreeAmigosCommandTest do
  @moduledoc """
  The prompt knows which story the task is for.

  Issue 989774cb: `start_task` was called with `entity_type: "story"` and
  `entity_id: "890"` and returned the generic prompt — "**Story not provided.**
  This task should always be scoped to a single story." The task was scoped, and
  the report carries the proof: `evaluate_task` on that same task passed and
  sealed 890 correctly. One resolver knew and the other did not.

  `resolve_command_story/2` matched `entity_id`, which a stored
  `Sessions.Task` does not have — it carries `story_id` — and then
  `requirement_name`, which on the graph route is "three_amigos_complete"
  rather than a story id. So both clauses missed and `command/2` answered
  `no_story_prompt/0`.

  The evaluate path's `resolve_story/2` already carries a comment saying exactly
  this ("A real `Sessions.Task` carries `story_id`, and nothing else"). The
  lesson was learned on one function and never applied to its neighbour, which
  is why the two disagreed about the same task.

  A prompt that says the story is unknown, on a task that knows it, teaches an
  agent to distrust the prompt — the cost is not the failed session, it is
  everything the agent stops believing afterwards.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ThreeAmigos

  setup do
    scope = full_scope_fixture()

    story =
      story_fixture(scope, %{
        title: "A timeline across the top says where my project is",
        description: "So I can see where the project stands without asking."
      })

    %{scope: scope, story: story}
  end

  describe "a task built by start_task" do
    test "names its story", %{scope: scope, story: story} do
      # The shape `build_task_attrs/3` produces: story_id set, no entity_id.
      task = %{
        requirement_name: "three_amigos_complete",
        project_id: scope.active_project.id,
        component_id: nil,
        story_id: story.id
      }

      {:ok, prompt} = ThreeAmigos.command(scope, task)

      refute prompt =~ "Story not provided",
             "the prompt told the agent to go and ask the PM which story this is, " <>
               "about a task that already carries the answer."

      assert prompt =~ story.title
    end

    test "the session URL points at that story", %{scope: scope, story: story} do
      task = %{
        requirement_name: "three_amigos_complete",
        project_id: scope.active_project.id,
        story_id: story.id
      }

      {:ok, prompt} = ThreeAmigos.command(scope, task)

      assert prompt =~ "/stories/#{story.number}/three-amigos",
             "without a story there is no session URL, so the PM has nowhere to " <>
               "watch the cards appear."
    end

    test "a story id that arrived as a string still resolves", %{scope: scope, story: story} do
      # `Session.add_task/2` casts through the embedded schema, so a stored task
      # holds an integer. Not every caller of `command/2` goes through that.
      task = %{requirement_name: "three_amigos_complete", story_id: to_string(story.id)}

      {:ok, prompt} = ThreeAmigos.command(scope, task)

      refute prompt =~ "Story not provided"
      assert prompt =~ story.title
    end
  end

  describe "the routes that already worked" do
    test "the graph route's entity_id still wins", %{scope: scope, story: story} do
      task = %{entity_type: "story", entity_id: to_string(story.id)}

      {:ok, prompt} = ThreeAmigos.command(scope, task)
      assert prompt =~ story.title
    end

    test "the skill route threads the story id through requirement_name", %{
      scope: scope,
      story: story
    } do
      # `/codemyspec:product three-amigos <story_id>`, per the topic-task
      # convention. Adding a story_id clause ahead of this must not shadow it.
      task = %{requirement_name: to_string(story.id)}

      {:ok, prompt} = ThreeAmigos.command(scope, task)
      assert prompt =~ story.title
    end

    test "a task with no story at all still says so", %{scope: scope} do
      {:ok, prompt} = ThreeAmigos.command(scope, %{requirement_name: "three_amigos_complete"})

      assert prompt =~ "Story not provided",
             "the generic prompt is the right answer when there really is no " <>
               "story — the defect was reaching it with one in hand."
    end

    test "a nil story_id does not shadow the other routes", %{scope: scope, story: story} do
      # `story_id` is a declared field, so it is present-and-nil on any task
      # built from the schema. A clause matching the key without guarding the
      # value would swallow every one of these.
      task = %{story_id: nil, entity_type: "story", entity_id: to_string(story.id)}

      {:ok, prompt} = ThreeAmigos.command(scope, task)
      assert prompt =~ story.title
    end
  end
end

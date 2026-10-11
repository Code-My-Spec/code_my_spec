defmodule CodeMySpecSpex.Fixtures.StoryIssueBag do
  @moduledoc "Pre-existing certification and review state for story issue acceptance scenarios."

  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  def certify(scope, story_id, revision) do
    story = Stories.get_story!(scope, story_id)
    {:ok, _} = Stories.set_qa_ready(scope, story, revision)
    :ok
  end

  def review(scope, story_id) do
    story = Stories.get_story!(scope, story_id)
    {_, task_id, _session} = Fixtures.qa_story_task_fixture(scope, story: story)
    {:ok, _} = Qa.capture_story_review(scope, %{id: task_id, story_id: story.id})
    task_id
  end
end

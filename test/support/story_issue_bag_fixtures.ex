defmodule CodeMySpecSpex.Fixtures.StoryIssueBag do
  @moduledoc "Pre-existing certification and review state for story issue acceptance scenarios."

  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  def certify(scope, story_id, revision) do
    story = Stories.get_story!(scope, story_id)
    {:ok, _} = Stories.set_qa_ready(scope, story, revision)
    :ok
  end

  def review(scope, story_id) do
    story = Stories.get_story!(scope, story_id)
    {_, task_id, _agent} = Fixtures.qa_story_task_fixture(scope, story: story)
    task_id
  end
end

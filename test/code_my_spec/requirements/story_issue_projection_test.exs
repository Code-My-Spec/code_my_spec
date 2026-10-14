defmodule CodeMySpec.Requirements.StoryIssueProjectionTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.IssuesFixtures
  import Ecto.Query

  alias CodeMySpec.Requirements.{NodeRepository, Projection, Requirement, Shadow}

  test "issue identity round trips and a visited story reaps its departed issue nodes" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    issue = issue_fixture(scope, %{story_id: story.id})

    node = %Requirement{
      entity_type: "issue",
      entity_id: issue.id,
      name: "submitted",
      details: %{story_id: story.id},
      parent_entity_id: story.id,
      satisfied: false
    }

    visited = %{components: [], stories: [story.id]}
    ids = NodeRepository.upsert_all(scope, [node], visited)
    assert is_integer(ids[{"issue", issue.id, "submitted"}])
    row = Repo.one!(from(n in Shadow.pass_target(), where: n.issue_id == ^issue.id))
    assert row.story_id == nil
    assert row.project_id == nil
    ctx = %{components: [], components_by_id: %{}, stories: [story], story_issues: [issue]}
    {[served], []} = Projection.load(scope, ctx, source: Shadow.pass_source())
    assert served.entity_type == "issue"
    assert served.entity_id == issue.id
    assert served.parent_entity_id == story.id
    assert NodeRepository.upsert_all(scope, [node], visited) == ids
    NodeRepository.upsert_all(scope, [], visited)
    refute Repo.exists?(from(n in Shadow.pass_target(), where: n.issue_id == ^issue.id))
  end

  test "event writer covers issue rows through their story, retaining stable ids" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    issue = issue_fixture(scope, %{story_id: story.id})

    node = %Requirement{
      entity_type: "issue",
      entity_id: issue.id,
      name: "submitted",
      details: %{story_id: story.id},
      satisfied: false
    }

    covered = [{"story", story.id}]
    assert {:ok, %{inserted: 1, reaped: 0}} = Shadow.write(scope, covered, [node])
    assert {:ok, %{inserted: 0, reaped: 0}} = Shadow.write(scope, covered, [node])
    assert {:ok, %{inserted: 0, reaped: 1}} = Shadow.write(scope, covered, [])
  end
end

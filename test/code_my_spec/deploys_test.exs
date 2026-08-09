defmodule CodeMySpec.DeploysTest do
  @moduledoc """
  What a deploy row means, and what it takes to get one.

  This is the read model the `deploy` requirement gates on. It replaced
  `.code_my_spec/devops/deploys/story_<id>.md` — a file the agent wrote for
  itself and the graph then believed — so the tests that matter here are the
  ones about what does *not* count.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Deploys

  setup do
    scope = full_scope_fixture()
    story = CodeMySpec.StoriesFixtures.story_fixture(scope)

    {:ok, scope: scope, story: story}
  end

  describe "a deploy only counts once its health check passed" do
    test "an unverified deploy is not deployed", ctx do
      {:ok, _deploy} = Deploys.record(ctx.scope, ctx.story.id, "uat")

      refute Deploys.deployed?(ctx.scope, ctx.story.id, "uat"),
             "a deploy that shipped and never answered read as done — criterion 1964 " <>
               "turns on exactly that not happening"
    end

    test "verifying it makes it count", ctx do
      {:ok, _deploy} = Deploys.record(ctx.scope, ctx.story.id, "uat")
      {:ok, _verified} = Deploys.verify(ctx.scope, ctx.story.id, "uat")

      assert Deploys.deployed?(ctx.scope, ctx.story.id, "uat")
    end

    test "a story with no deploy at all is not deployed", ctx do
      refute Deploys.deployed?(ctx.scope, ctx.story.id, "uat")
    end
  end

  describe "environments are separate" do
    test "uat does not imply prod", ctx do
      {:ok, _} = Deploys.record(ctx.scope, ctx.story.id, "uat", health_verified_at: DateTime.utc_now())

      assert Deploys.deployed?(ctx.scope, ctx.story.id, "uat")

      refute Deploys.deployed?(ctx.scope, ctx.story.id, "prod"),
             "prod promotion belongs to the release process — a UAT deploy must not stand in for it"
    end
  end

  describe "redeploying" do
    # One row per story per environment, so "is this story on UAT" is a lookup
    # rather than a question about the newest of several rows.
    test "a redeploy updates rather than accumulating", ctx do
      {:ok, first} = Deploys.record(ctx.scope, ctx.story.id, "uat", commit_sha: "aaa")
      {:ok, second} = Deploys.record(ctx.scope, ctx.story.id, "uat", commit_sha: "bbb")

      assert first.id == second.id
      assert second.commit_sha == "bbb"
      assert length(Deploys.list(ctx.scope)) == 1
    end
  end

  describe "uat_check/2 — the requirement's answer" do
    test "false, with a reason, when the story is not on UAT", ctx do
      assert {false, %{status: status}} = Deploys.uat_check(ctx.scope, ctx.story)
      assert status =~ "Not deployed"
    end

    test "true once it is deployed and verified", ctx do
      {:ok, _} = Deploys.record(ctx.scope, ctx.story.id, "uat", health_verified_at: DateTime.utc_now())

      assert {true, %{status: status}} = Deploys.uat_check(ctx.scope, ctx.story)
      assert status =~ "health-verified"
    end
  end

  describe "record_environment_deploy/3" do
    # A deploy ships the application, not one story, so what it carries is
    # every story that had cleared QA. Stories still in QA are left out
    # deliberately — their code may be in the image, but the claim is about
    # work that was finished and checked.
    test "records only the stories that cleared QA", ctx do
      passed = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{title: "cleared qa"})
      CodeMySpec.QaFixtures.passed_qa_attempt(ctx.scope, story_id: passed.id)

      _in_progress = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{title: "still in qa"})

      {:ok, recorded} = Deploys.record_environment_deploy(ctx.scope, "uat")

      assert Enum.map(recorded, & &1.story_id) == [passed.id]
      assert Deploys.deployed?(ctx.scope, passed.id, "uat")
    end

    test "what it records is health-verified", ctx do
      passed = CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{title: "cleared qa"})
      CodeMySpec.QaFixtures.passed_qa_attempt(ctx.scope, story_id: passed.id)

      {:ok, [deploy]} = Deploys.record_environment_deploy(ctx.scope, "uat")

      assert %DateTime{} = deploy.health_verified_at,
             "the step calls this only after its probe passed, so the row it writes says so"
    end
  end
end

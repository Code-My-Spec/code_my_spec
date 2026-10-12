defmodule CodeMySpec.PromotionQueue.APromoteIsCheckedAtItsCommitTest do
  @moduledoc """
  A story is certified at a commit, and its promotion is checked at the
  candidate commit (2026-10-11).

  Story 1091's QA passed at one commit, two test-only commits followed, and the
  queue refused the candidate at landing on every retry — holding every other
  candidate behind it — while the graph went on reporting the story done. A
  re-queue that named no story then landed the same work as plain code,
  skipping the QA check and leaving the story unstamped.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecTest.PromotionQueueHelpers

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.Qa
  alias CodeMySpec.QaFixtures
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    root = CodeMySpec.TempFile.dir("story-copy")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "story"])
    git!(root, ["config", "user.email", "t@example.com"])
    git!(root, ["config", "user.name", "T"])
    File.write!(Path.join(root, "app.ex"), "defmodule App do\nend\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "the story"])
    on_exit(fn -> File.rm_rf(root) end)

    # The first copy to report a root is main, and main's promote is a restart.
    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))

    {:ok, _main} =
      WorkingCopies.report_root(main, "/tmp/story-main-#{System.unique_integer([:positive])}")

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a team", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, root)

    scope =
      put_fixture_environment(
        %{scope | active_working_copy_id: copy.id},
        Environment.new(:local, root)
      )

    on_exit(fn -> stop_worker(scope.active_project_id) end)

    %{
      scope: scope,
      copy: copy,
      story: story_fixture(scope, %{working_copy_id: copy.id}),
      head: git!(root, ["rev-parse", "HEAD"])
    }
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    String.trim(out)
  end

  defp queued(scope), do: Repository.queued(scope.active_project_id, 10)

  defp certified_at(ctx, commit) do
    {:ok, story} = Stories.set_qa_ready(ctx.scope, ctx.story, commit)
    story
  end

  test "a promote naming no story is the promotion of the certified story assigned to the copy",
       ctx do
    certified_at(ctx, ctx.head)

    assert {:error, %{reason: reason}} = PromotionQueue.promote(ctx.scope, nil)

    assert reason =~ "story #{ctx.story.number} has not passed QA",
           "the candidate was taken as plain code, which skips the QA check"

    assert queued(ctx.scope) == []
  end

  test "a story certified at its commit with a current pass is queued as that story", ctx do
    certified_at(ctx, ctx.head)
    {:ok, _} = QaFixtures.passed_qa_attempt(ctx.scope, story_id: ctx.story.id)

    assert {:ok, %{queued: entry}} = PromotionQueue.promote(ctx.scope, nil)
    assert {entry.subject_type, entry.subject_id} == {:story, to_string(ctx.story.number)}
  end

  test "a stamp the branch moved past is released, keeping the pass to carry", ctx do
    earlier = String.duplicate("4", 40)
    certified_at(ctx, earlier)
    {:ok, _} = QaFixtures.passed_qa_attempt(ctx.scope, story_id: ctx.story.id)

    assert {:error, %{reason: reason}} = PromotionQueue.promote(ctx.scope, ctx.story.number)
    assert reason =~ "certified at #{earlier}, not at this copy's HEAD #{ctx.head}"
    assert queued(ctx.scope) == []

    story = Stories.get_story(ctx.scope, ctx.story.id)
    assert story.qa_ready_commit == nil, "the graph would go on reporting the story ready"

    assert story.qa_reviewed_commit == earlier,
           "the pass was forgotten, so a test-only change would cost another QA pass"

    refute Qa.story_review_current?(ctx.scope, story.id)
  end

  test "a promote with nothing assigned is plain code", ctx do
    {:ok, story} = Stories.update_story(ctx.scope, ctx.story, %{working_copy_id: nil})
    certified_at(%{ctx | story: story}, ctx.head)

    assert {:ok, %{queued: entry}} = PromotionQueue.promote(ctx.scope, nil)
    assert entry.subject_type == nil, "work assigned nowhere was taken for a story's promotion"
  end

  test "a copy reporting a HEAD past its story's stamp releases it", ctx do
    earlier = String.duplicate("4", 40)
    certified_at(ctx, earlier)
    {:ok, _} = QaFixtures.passed_qa_attempt(ctx.scope, story_id: ctx.story.id)

    assert PromotionQueue.release_moved_certifications(ctx.scope, ctx.copy.id, earlier) == []
    assert [_] = PromotionQueue.release_moved_certifications(ctx.scope, ctx.copy.id, ctx.head)

    story = Stories.get_story(ctx.scope, ctx.story.id)
    assert story.qa_ready_commit == nil, "the graph would go on reporting the story ready for QA"
    assert story.qa_reviewed_commit == earlier, "the pass was dropped instead of kept to carry"
  end
end

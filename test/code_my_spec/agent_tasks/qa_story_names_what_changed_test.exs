defmodule CodeMySpec.AgentTasks.QaStoryNamesWhatChangedTest do
  @moduledoc """
  QA re-offered a story is told what changed since its last attempt.

  metric_flow story 47, 2026-09-29: coding resolved both highs QA had filed,
  QA was re-offered the story, concluded "no code has changed" and tapped out
  (255f1dcd rule 4).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.QaAttempt

  setup do
    scope = working_copy_scope_fixture()

    scope =
      put_fixture_environment(
        scope,
        Environment.new(:local, CodeMySpec.TempFile.owned_dir("qa_changed"))
      )

    story = story_fixture(scope, %{title: "Stripe connect"})
    %{scope: scope, story: story, task: %{story_id: story.id}}
  end

  defp resolved!(scope, story, title) do
    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: title,
        description: "…",
        severity: :high,
        story_id: story.id
      })

    {:ok, issue} = Issues.accept_issue(scope, issue)
    {:ok, issue} = Issues.resolve_issue(scope, issue, "fixed #{title}")
    issue
  end

  defp attempt!(story, issue_ids) do
    %QaAttempt{}
    |> QaAttempt.changeset(%{
      story_id: story.id,
      status: :fail,
      scenarios: [%{name: "connect", status: :fail, observation: "broken"}],
      issue_ids: issue_ids,
      agent_id: "qa",
      submitted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "a first attempt gets no change list", ctx do
    {:ok, prompt} = QaStory.command(ctx.scope, ctx.task)
    refute prompt =~ "since your last attempt"
  end

  test "the re-offered prompt lists issues resolved and how to see commits since", ctx do
    before = resolved!(ctx.scope, ctx.story, "Fixed before the attempt")
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    Repo.update_all(from(i in Issue, where: i.id == ^before.id), set: [updated_at: past])

    attempt = attempt!(ctx.story, [before.id])
    later = DateTime.add(attempt.submitted_at, 1, :second)
    after_attempt = resolved!(ctx.scope, ctx.story, "Webhook handler wired")
    Repo.update_all(from(i in Issue, where: i.id == ^after_attempt.id), set: [updated_at: later])

    {:ok, prompt} = QaStory.command(ctx.scope, ctx.task)

    assert prompt =~ "since your last attempt"
    assert prompt =~ "Webhook handler wired"
    assert prompt =~ "fixed Webhook handler wired"
    refute prompt =~ "Fixed before the attempt"
    assert prompt =~ "git log --oneline --since=#{DateTime.to_iso8601(attempt.submitted_at)}"
  end
end

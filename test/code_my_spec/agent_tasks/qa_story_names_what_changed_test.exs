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

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.WorkingCopies

  setup do
    scope = working_copy_scope_fixture()

    scope =
      put_fixture_execution_context(
        scope,
        ExecutionContext.new(:local, CodeMySpec.TempFile.owned_dir("qa_changed"))
      )

    story = story_fixture(scope, %{title: "Stripe connect"})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, _} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/qa-changes",
        working_copy_id: copy.id,
        role: :coding,
        status: :running,
        story_id: story.id
      })

    scope = %{scope | active_working_copy_id: copy.id}

    %{scope: scope, story: story, task: %{id: Ecto.UUID.generate(), story_id: story.id}}
  end

  defp submitted!(scope, story, title) do
    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: title,
        description: "…",
        severity: :high,
        story_id: story.id
      })

    {:ok, issue} = Issues.accept_issue(scope, issue)

    {:ok, issue} =
      Issues.submit_story_issue(scope, issue, %{revision: "fix-sha", evidence: "fixed #{title}"})

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
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, story, "fix-sha")
    {:ok, prompt} = QaStory.command(ctx.scope, ctx.task)
    refute prompt =~ "since your last attempt"
  end

  test "the re-offered prompt lists issues submitted and how to see commits since", ctx do
    before = submitted!(ctx.scope, ctx.story, "Fixed before the attempt")
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    Repo.update_all(from(i in Issue, where: i.id == ^before.id), set: [story_submitted_at: past])

    attempt = attempt!(ctx.story, [before.id])
    later = DateTime.add(attempt.submitted_at, 1, :second)
    after_attempt = submitted!(ctx.scope, ctx.story, "Webhook handler wired")

    Repo.update_all(from(i in Issue, where: i.id == ^after_attempt.id),
      set: [story_submitted_at: later]
    )

    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, story, "fix-sha")
    {:ok, prompt} = QaStory.command(ctx.scope, ctx.task)

    assert prompt =~ "since your last attempt"
    assert prompt =~ "Webhook handler wired"
    assert prompt =~ "fixed Webhook handler wired"
    refute prompt =~ "Fixed before the attempt"
    assert prompt =~ "git log --oneline --since=#{DateTime.to_iso8601(attempt.submitted_at)}"
  end
end

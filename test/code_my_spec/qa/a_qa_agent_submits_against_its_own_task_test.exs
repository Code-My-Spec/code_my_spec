defmodule CodeMySpec.Qa.AQaAgentSubmitsAgainstItsOwnTaskTest do
  @moduledoc """
  A QA agent we run holds its own task, and submitting had to find it.

  `resolve_task_info/2` searched `Session.tasks` and nothing else. An agent
  under Alloy keeps its tasks on the agent row — that is what `TaskOwner`
  exists for — so a real task id came back `task_not_found`, the honest answer
  to the wrong question.

  Watched on the war-epic copy, 2026-09-06: "QA is blocked: the required result
  submission returns `task_not_found` because this conversation has no
  registered session." The agent's diagnosis was right and the remedy it
  inferred — register a session — is not something it can do. So it stopped,
  was nudged about the still-open `qa_complete`, and repeated for an hour
  without submitting anything.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    story =
      story_fixture(scope)
      |> Ecto.Changeset.change(
        qa_ready_at: DateTime.utc_now(),
        qa_ready_commit: "reviewed-revision"
      )
      |> Repo.update!()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        working_copy: "/tmp/qa-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    task_id = Ecto.UUID.generate()

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        id: task_id,
        status: :active,
        requirement_name: "qa_complete",
        story_id: story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    {:ok, _review} = Qa.capture_story_review(scope, %{id: task_id, story_id: story.id})
    %{scope: scope, story: story, agent: agent, task_id: task_id}
  end

  defp attrs(task_id, status) do
    %{
      task_id: task_id,
      status: status,
      scenarios: [
        %{
          "name" => "the city falls",
          "status" => "pass",
          "observation" => "the capital changed hands and the realm became a vassal"
        }
      ]
    }
  end

  test "the attempt lands against a task held by the agent", ctx do
    assert {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    assert attempt.task_id == ctx.task_id
    assert attempt.story_id == ctx.story.id
  end

  test "a promoted reviewed submission stays current and completes idempotently", ctx do
    issue =
      CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{
        story_id: ctx.story.id,
        severity: :high
      })

    {:ok, issue} = CodeMySpec.Issues.accept_issue(ctx.scope, issue)
    ref = Ecto.UUID.generate()

    issue
    |> Ecto.Changeset.change(
      story_submission_ref: ref,
      story_submission_revision: "reviewed-revision",
      story_submission_evidence: "fixed",
      story_submitted_at: DateTime.utc_now()
    )
    |> Repo.update!()

    task_id = Ecto.UUID.generate()

    ctx.agent
    |> Agent.add_task(%{
      id: task_id,
      status: :active,
      requirement_name: "qa_complete",
      story_id: ctx.story.id
    })
    |> Repo.update!()

    assert {:ok, _} = Qa.capture_story_review(ctx.scope, %{id: task_id, story_id: ctx.story.id})
    assert {:ok, _} = Qa.submit_qa_result(ctx.scope, attrs(task_id, :pass))
    assert Qa.story_review_current?(ctx.scope, ctx.story.id)

    assert {:ok, [_]} =
             Qa.complete_reviewed_story_issues(
               ctx.scope,
               ctx.story,
               "landed-revision",
               "reviewed-revision"
             )

    assert Qa.story_review_current?(ctx.scope, ctx.story.id)
    assert Qa.qa_complete?(ctx.scope, ctx.story.id)

    assert {:ok, [_]} =
             Qa.complete_reviewed_story_issues(
               ctx.scope,
               ctx.story,
               "landed-revision",
               "reviewed-revision"
             )

    assert CodeMySpec.Issues.get_issue(ctx.scope, issue.id).status == :resolved
  end

  test "promotion cannot resolve a newer review using an older queued candidate", ctx do
    {:ok, _attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))
    refute Qa.story_review_current?(ctx.scope, ctx.story.id, "older-candidate")

    assert {:error, :no_current_story_qa_pass} =
             Qa.complete_reviewed_story_issues(
               ctx.scope,
               ctx.story,
               "landed-revision",
               "older-candidate"
             )

    assert {:error, %{landed: true, assignment_held: true, landed_commit: "landed-revision"}} =
             CodeMySpec.Promotion.record_landed_stories(
               ctx.scope,
               [{ctx.story, ctx.agent.working_copy_id, "older-candidate"}],
               "1.0.0",
               "landed-revision"
             )

    assert is_nil(CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id).promoted_at)
  end

  test "an incoming low holds promotion without invalidating the reviewed pass", ctx do
    assert {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    issue =
      CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{story_id: ctx.story.id, severity: :low})

    refute Qa.story_review_current?(ctx.scope, ctx.story.id)

    assert {:error, :story_issues_not_triaged} =
             Qa.complete_reviewed_story_issues(
               ctx.scope,
               ctx.story,
               "landed-revision",
               "reviewed-revision"
             )

    assert {:error, :story_issues_not_triaged} =
             Qa.capture_story_review(ctx.scope, %{
               id: Ecto.UUID.generate(),
               story_id: ctx.story.id
             })

    assert {:ok, _} =
             Qa.capture_story_review(ctx.scope, %{id: ctx.task_id, story_id: ctx.story.id})

    assert Qa.qa_complete?(ctx.scope, ctx.story.id)
    assert {:ok, _} = CodeMySpec.Issues.dismiss_issue(ctx.scope, issue, "Not a defect")
    assert Qa.story_review_current?(ctx.scope, ctx.story.id, "reviewed-revision")
    assert [unchanged] = Qa.list_qa_attempts(ctx.scope, ctx.story.id)
    assert unchanged.id == attempt.id
    assert unchanged.invalidations == []
  end

  test "all QA verdict readers reject cleared certification", ctx do
    {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    story =
      ctx.story |> Ecto.Changeset.change(qa_ready_at: nil, qa_ready_commit: nil) |> Repo.update!()

    attempt = Repo.preload(attempt, :invalidations)
    refute Qa.qa_complete?(ctx.scope, story.id)
    assert {false, _} = Qa.complete_check(ctx.scope, story)

    assert {false, _} =
             Qa.complete_check(ctx.scope, story, %{qa_latest_by_story: %{story.id => attempt}})
  end

  test "a reviewless historical row cannot approve current story QA", ctx do
    {:ok, attempt} = CodeMySpec.QaFixtures.passed_qa_attempt(ctx.scope, story_id: ctx.story.id)

    attempt
    |> Ecto.Changeset.change(review_id: nil, review_started_at: nil, review_certified_at: nil)
    |> Repo.update!()

    refute Qa.qa_complete?(ctx.scope, ctx.story.id)
  end

  test "a late passing result cannot approve a newly certified revision", ctx do
    ctx.story
    |> Ecto.Changeset.change(qa_ready_commit: "newer-revision", qa_ready_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))
    assert attempt.stale
    refute Qa.qa_complete?(ctx.scope, ctx.story.id)
    assert [stored] = Qa.list_qa_attempts(ctx.scope, ctx.story.id)
    assert stored.id == attempt.id
  end

  test "resuming a superseded task requires a fresh QA task", ctx do
    {:ok, original} =
      Qa.capture_story_review(ctx.scope, %{id: ctx.task_id, story_id: ctx.story.id})

    ctx.story |> Ecto.Changeset.change(qa_ready_commit: "newer-revision") |> Repo.update!()

    assert {:error, :qa_review_superseded} =
             Qa.capture_story_review(ctx.scope, %{id: ctx.task_id, story_id: ctx.story.id})

    assert Repo.get!(CodeMySpec.Qa.StoryReview, original.id).certified_revision ==
             "reviewed-revision"
  end

  # Who did the QA. `TaskOwner.activate_task/4` sets `task.agent_id` on its
  # session clause and not its agent one — an agent-owned task does not name an
  # agent, because the row it lives on already is one. So two real QA passes on
  # story 1000 landed this morning attributed to nobody, and "which agent tested
  # this" had no answer.
  test "the attempt names the agent that made it", ctx do
    {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    assert attempt.agent_id == ctx.agent.id
  end

  # The story comes off the task, not off the submission — a QA agent that had
  # to state it could state the wrong one, and nothing in the payload would say
  # so. `:pass` rather than `:fail` because a failure has to cite issue ids,
  # which is a different rule and not the one under test here.
  test "the story is taken from the task, not from the caller", ctx do
    {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

    assert attempt.story_id == ctx.story.id
    refute Map.has_key?(attrs(ctx.task_id, :pass), :story_id)
  end

  # The refusal still has to work. A task id belonging to nothing is not the
  # same as one this could not look in the right place for.
  test "an id that is on neither an agent nor a session is refused", ctx do
    assert {:error, {:task_not_found, _open}} =
             Qa.submit_qa_result(ctx.scope, attrs(Ecto.UUID.generate(), :pass))
  end

  # The refusal the war-epic agent needed and did not get. It submitted story
  # 1000's id as the task id, was told `task_not_found`, and concluded its
  # session was unregistered — a cause that was not there and that it could not
  # have acted on.
  test "a story id passed as a task id is refused with the real one", ctx do
    story_id_as_task = to_string(ctx.story.id)

    assert {:error, {:task_not_found, open}} =
             Qa.submit_qa_result(ctx.scope, attrs(story_id_as_task, :pass))

    assert {ctx.task_id, ctx.story.id} in open,
           "the refusal did not name the open QA task, so the agent has nothing " <>
             "to correct its guess with"
  end

  # 257a6a15: scenarios and prose describe what QA found, never how the
  # evidence was gathered. tools_used is self-reported the same way the
  # observation text already is — this pins that it round-trips, and that
  # nil (never asked) and [] (asked, answered none) stay distinguishable.
  describe "tools_used" do
    test "records the tools an agent reports calling", ctx do
      submitted =
        Map.put(attrs(ctx.task_id, :pass), :tools_used, ["browser_navigate", "browser_click"])

      {:ok, attempt} = Qa.submit_qa_result(ctx.scope, submitted)

      assert attempt.tools_used == ["browser_navigate", "browser_click"]
    end

    test "an attempt that never answers the question records nil, not []", ctx do
      {:ok, attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))

      assert attempt.tools_used == nil,
             "an old-shaped submission that never mentions tools_used must not be " <>
               "recorded the same as one that explicitly reported calling none"
    end

    test "an agent that explicitly reports calling nothing records []", ctx do
      submitted = Map.put(attrs(ctx.task_id, :pass), :tools_used, [])

      {:ok, attempt} = Qa.submit_qa_result(ctx.scope, submitted)

      assert attempt.tools_used == []
    end
  end
end

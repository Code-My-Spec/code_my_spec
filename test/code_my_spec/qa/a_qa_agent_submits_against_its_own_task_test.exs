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

  require Phoenix.LiveViewTest

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.Tools.SubmitQaResult
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

    {:ok, _review} = capture(scope, agent.id, task_id)
    %{scope: scope, story: story, agent: agent, task_id: task_id}
  end

  # The task as its agent holds it now, so a capture sees what earlier ones
  # recorded on it.
  defp held_task(agent_id, task_id),
    do: Agent |> Repo.get!(agent_id) |> Map.fetch!(:tasks) |> Enum.find(&(&1.id == task_id))

  defp capture(scope, agent_id, task_id) do
    agent = Repo.get!(Agent, agent_id)
    Qa.capture_story_review(scope, agent, held_task(agent_id, task_id))
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

  test "a passing verdict cannot contain a failed or blocked scenario", ctx do
    blocker = Ecto.UUID.generate()

    for status <- ["fail", "blocked"] do
      params = attrs(ctx.task_id, :pass) |> Map.put(:issue_ids, [blocker])

      scenarios =
        Enum.map(params.scenarios, fn scenario ->
          scenario |> Map.put("status", status) |> Map.put("blocker_issue_id", blocker)
        end)

      assert {:error, %Ecto.Changeset{}} =
               Qa.submit_qa_result(ctx.scope, %{params | scenarios: scenarios})

      assert Qa.list_qa_attempts(ctx.scope, ctx.story.id) == []
      assert held_task(ctx.agent.id, ctx.task_id).status == :active
    end
  end

  test "a partial verdict preserves a blocked scenario and its blocker", ctx do
    blocker = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{severity: :high})

    params =
      attrs(ctx.task_id, :partial)
      |> Map.put(:issue_ids, [blocker.id])
      |> Map.put(:scenarios, [
        %{
          "name" => "live check",
          "status" => "blocked",
          "observation" => "The test service is unavailable",
          "blocker_issue_id" => blocker.id
        }
      ])

    assert {:ok, attempt} = Qa.submit_qa_result(ctx.scope, params)
    stored = Repo.get!(Qa.QaAttempt, attempt.id)
    assert [scenario] = stored.scenarios
    assert scenario.status == :blocked
    assert Map.fetch!(scenario, :blocker_issue_id) == blocker.id
    refute Qa.qa_complete?(ctx.scope, ctx.story.id)

    html =
      Phoenix.LiveViewTest.render_component(
        &CodeMySpecWeb.StoryLive.QaHistoryComponent.qa_history/1,
        attempts: Repo.preload([stored], :invalidations)
      )

    assert html =~ "blocked"
    assert html =~ "Blocked by issue"
    assert html =~ blocker.id

    assert {:ok, [row]} =
             CodeMySpec.Qa.Tools.ListQaAttempts.script_result(
               %{story_number: ctx.story.number},
               %{scope: ctx.scope}
             )

    assert [%{"status" => "blocked", "blocker_issue_id" => exported_blocker}] = row["scenarios"]
    assert exported_blocker == blocker.id
  end

  # ed0e0e81: QA cites an issue by the key it is shown (an id prefix), and
  # the tool refused it as an invalid id.
  test "an issue cited by its key is recorded by its full id", ctx do
    blocker = CodeMySpec.IssuesFixtures.issue_fixture(ctx.scope, %{severity: :high})
    key = String.slice(blocker.id, 0, 8)

    params =
      attrs(ctx.task_id, :partial)
      |> Map.put(:issue_ids, [key])
      |> Map.put(:scenarios, [
        %{
          "name" => "live check",
          "status" => "blocked",
          "observation" => "The test service is unavailable",
          "blocker_issue_id" => key
        }
      ])

    assert {:ok, _text} = SubmitQaResult.call(params, %{scope: ctx.scope})
    assert [attempt] = Qa.list_qa_attempts(ctx.scope, ctx.story.id)
    assert attempt.issue_ids == [blocker.id]
    assert [%{blocker_issue_id: blocker_id}] = Repo.get!(Qa.QaAttempt, attempt.id).scenarios
    assert blocker_id == blocker.id
  end

  test "an issue key that matches nothing is refused, saying so", ctx do
    params = attrs(ctx.task_id, :partial) |> Map.put(:issue_ids, ["ffffffff"])

    assert {:error, message} =
             SubmitQaResult.call(params, %{scope: ctx.scope})

    assert message =~ "No issue matches `ffffffff`"
    assert Qa.list_qa_attempts(ctx.scope, ctx.story.id) == []
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

    assert {:ok, _} = capture(ctx.scope, ctx.agent.id, task_id)
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
             Qa.capture_story_review(ctx.scope, ctx.agent, %{
               id: Ecto.UUID.generate(),
               story_id: ctx.story.id
             })

    assert {:ok, _} = capture(ctx.scope, ctx.agent.id, ctx.task_id)

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
    |> Ecto.Changeset.change(
      reviewed_commit: nil,
      review_started_at: nil,
      review_certified_at: nil
    )
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

  test "a pass carried to a new certification counts there, and only there", ctx do
    {:ok, _attempt} = Qa.submit_qa_result(ctx.scope, attrs(ctx.task_id, :pass))
    story = CodeMySpec.Stories.get_story!(ctx.scope, ctx.story.id)
    reviewed = {story.qa_ready_commit, story.qa_ready_at}

    {:ok, _} =
      CodeMySpec.Stories.set_qa_ready(
        ctx.scope,
        story,
        "test-only-commit",
        DateTime.utc_now(),
        reviewed
      )

    assert Qa.qa_complete?(ctx.scope, story.id)
    assert Qa.story_review_current?(ctx.scope, story.id, "test-only-commit")

    refute Qa.story_review_current?(ctx.scope, story.id, "reviewed-revision"),
           "promotion asks at the candidate, and the story is no longer certified there"

    {:ok, _} = CodeMySpec.Stories.set_qa_ready(ctx.scope, story, "product-commit")
    refute Qa.qa_complete?(ctx.scope, story.id)
  end

  test "resuming a superseded task requires a fresh QA task", ctx do
    {:ok, original} = capture(ctx.scope, ctx.agent.id, ctx.task_id)

    ctx.story |> Ecto.Changeset.change(qa_ready_commit: "newer-revision") |> Repo.update!()

    assert {:error, :qa_review_superseded} = capture(ctx.scope, ctx.agent.id, ctx.task_id)

    assert original.commit == "reviewed-revision"
    assert held_task(ctx.agent.id, ctx.task_id).review_commit == "reviewed-revision"
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

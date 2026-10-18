defmodule CodeMySpec.Issues.StorySubmissionsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/story-submissions",
        role: :coding,
        status: :running,
        working_copy_id: copy.id,
        story_id: story.id
      })

    issue = issue_fixture(scope, %{status: :accepted, story_id: story.id, severity: :high})
    %{scope: %{scope | active_working_copy_id: copy.id}, issue: issue, story: story, agent: agent}
  end

  test "project-only graph scopes can read snapshots without widening project scope", ctx do
    scope = %CodeMySpec.Users.Scope{active_project_id: ctx.scope.active_project_id}
    assert Issues.story_submission_snapshot(scope, ctx.story.id) == %{ctx.issue.id => nil}
    other = %CodeMySpec.Users.Scope{active_project_id: Ecto.UUID.generate()}
    assert Issues.story_submission_snapshot(other, ctx.story.id) == %{}
  end

  test "inherited issues cannot bypass shared QA and promotion", ctx do
    assert {:error, :story_issue_requires_shared_qa_and_promotion} =
             Issues.resolve_issue(ctx.scope, ctx.issue, "coder says fixed")
  end

  test "submission is idempotent and keeps the issue accepted", ctx do
    attrs = %{revision: "commit-one", evidence: "fixed and tested"}
    assert {:ok, first} = Issues.submit_story_issue(ctx.scope, ctx.issue, attrs)
    assert first.status == :accepted
    assert is_binary(first.story_submission_ref)
    assert {:ok, duplicate} = Issues.submit_story_issue(ctx.scope, ctx.issue, attrs)
    assert duplicate.story_submission_ref == first.story_submission_ref
    assert length(duplicate.story_submission_history) == 1

    assert Issues.story_submission_snapshot(ctx.scope, ctx.story.id) ==
             %{first.id => first.story_submission_ref}
  end

  test "wrong working copy and missing evidence cannot submit", ctx do
    assert {:error, :submission_revision_and_evidence_required} =
             Issues.submit_story_issue(ctx.scope, ctx.issue, %{revision: "a"})

    scope = %{ctx.scope | active_working_copy_id: Ecto.UUID.generate()}

    assert {:error, :story_not_assigned_to_working_copy} =
             Issues.submit_story_issue(scope, ctx.issue, %{revision: "a", evidence: "tested"})
  end

  test "rework retains history and resubmission rejects stale promotion", ctx do
    attrs = %{revision: "a", evidence: "tested"}
    {:ok, first} = Issues.submit_story_issue(ctx.scope, ctx.issue, attrs)
    old = %{first.id => first.story_submission_ref}

    assert {:ok, [returned]} =
             Issues.rework_story_submissions(
               ctx.scope,
               ctx.story.id,
               old,
               [first.id],
               "still fails"
             )

    assert returned.story_submission_ref == nil
    {:ok, second} = Issues.submit_story_issue(ctx.scope, returned, attrs)
    refute second.story_submission_ref == first.story_submission_ref
    assert length(second.story_submission_history) == 3

    assert {:error, :stale_story_submission} =
             Issues.complete_story_submissions(ctx.scope, ctx.story.id, old, "landed")

    assert {:ok, [completed]} =
             Issues.complete_story_submissions(
               ctx.scope,
               ctx.story.id,
               %{second.id => second.story_submission_ref},
               "landed"
             )

    assert completed.status == :resolved
    assert completed.landed_commit == "landed"

    assert Issues.story_submission_snapshot(ctx.scope, ctx.story.id) ==
             %{second.id => second.story_submission_ref}

    assert {:ok, [same]} =
             Issues.complete_story_submissions(
               ctx.scope,
               ctx.story.id,
               %{second.id => second.story_submission_ref},
               "landed"
             )

    assert same.id == completed.id

    assert {:ok, [historical]} =
             Issues.complete_story_submissions(
               ctx.scope,
               ctx.story.id,
               %{second.id => second.story_submission_ref},
               "later-story-landing"
             )

    assert historical.landed_commit == "landed"
  end

  test "changed submission clears readiness while duplicates preserve renewed certification",
       ctx do
    stamp = %{qa_ready_commit: "before", qa_ready_at: DateTime.utc_now()}
    ctx.story |> Ecto.Changeset.change(stamp) |> Repo.update!()
    attrs = %{revision: "a", evidence: "tested"}
    {:ok, _} = Issues.submit_story_issue(ctx.scope, ctx.issue, attrs)
    assert Repo.reload!(ctx.story).qa_ready_commit == nil
    ctx.story |> Ecto.Changeset.change(%{qa_ready_commit: "recertified"}) |> Repo.update!()
    {:ok, _} = Issues.submit_story_issue(ctx.scope, ctx.issue, attrs)
    assert Repo.reload!(ctx.story).qa_ready_commit == "recertified"
  end

  test "tool requires the authenticated coding owner", ctx do
    alias Anubis.Server.Frame
    params = %{issue_id: ctx.issue.id, revision: "a", evidence: "tested"}
    frame = %Frame{assigns: %{current_scope: ctx.scope}}

    denied =
      ToolLibrary.run(
        "submit_story_issue",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:error, _}, denied)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.agent.id}}

    submitted =
      ToolLibrary.run(
        "submit_story_issue",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, submitted)
  end

  test "evaluate_task closes a submitted inherited issue task through its own evaluator", ctx do
    alias Anubis.Server.Frame
    alias CodeMySpec.AgentTasks.SubmitStoryIssue
    alias CodeMySpec.TaskOwner

    id = Ecto.UUID.generate()

    {:ok, _} =
      TaskOwner.add_task(ctx.scope, ctx.agent, %{
        id: id,
        status: :active,
        requirement_name: "submitted",
        session_type: SubmitStoryIssue,
        story_id: ctx.story.id,
        issue_id: ctx.issue.id,
        project_id: ctx.scope.active_project_id
      })

    {:ok, _} =
      Issues.submit_story_issue(ctx.scope, ctx.issue, %{revision: "a", evidence: "tested"})

    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: ctx.agent.id}}

    result =
      ToolLibrary.run(
        "evaluate_task",
        %{task_id: id},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, result)
    {:ok, owner} = CodeMySpec.Agents.fetch_agent(ctx.scope, ctx.agent.id)
    assert TaskOwner.find_task(owner, id).status == :completed
  end

  test "explicit issue bags stay out of story submissions", ctx do
    {:ok, assigned} =
      Issues.set_assigned_working_copy(
        ctx.scope,
        ctx.issue,
        ctx.scope.active_working_copy_id
      )

    assert Issues.story_submission_snapshot(ctx.scope, ctx.story.id) == %{}

    assert {:error, :not_an_inherited_story_issue} =
             Issues.submit_story_issue(
               ctx.scope,
               assigned,
               %{revision: "a", evidence: "tested"}
             )
  end
end

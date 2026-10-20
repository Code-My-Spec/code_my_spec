defmodule CodeMySpec.Agents.Main.AResolvedQuestionIsARecordMainCanCiteTest do
  @moduledoc """
  Issue 5a78b7c4: a story's own resolved Question (BDD red card, resolved via
  `resolve_question`) is a project record as direct as an accepted issue or a
  known checkout, but `recorded?/3` checked only three readings
  (`epic_membership`, `fleet`, `filed_issues`) and had no way to see it. A
  decision main recorded exactly where the project tracks it still could not
  be cited back through `answer_notification` with `basis: "record"`.

  `recorded?/3` now also checks `resolved_questions/3`: a resolved Question on
  the *same story* as the one being answered, named by its short id, the same
  way `filed_issues/2` already names an issue.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Notifications
  alias CodeMySpec.Questions
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}
    story = story_fixture(scope)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: true,
        working_copy: "/tmp/resolved-question-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)
    {:ok, agent} = TaskOwner.add_task(scope, agent, %{status: :active, story_id: story.id})

    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "a question",
          "questions" => [%{"question" => "Should X ship this cycle?", "options" => []}],
          "holder" => "main_agent"
        }
      )

    %{scope: scope, story: story, request: request}
  end

  test "an answer citing a resolved Question on the same story is recorded", ctx do
    {:ok, question} =
      Questions.create_question(ctx.scope, ctx.story.id, %{text: "Ship this cycle?"})

    {:ok, resolved} = Questions.resolve_question(ctx.scope, question, "Yes, ship it this cycle.")

    short_id = String.slice(resolved.id, 0, 8)
    answer = "Yes, already decided (see #{short_id})."

    assert {:ok, _} =
             MainAgent.answer_question(ctx.scope, ctx.request.id, answer, basis: "record"),
           "an answer citing a resolved Question's own id on the same story was refused as unrecorded"
  end

  test "the tool explains a missing record, escalation, and how to retry", ctx do
    alias CodeMySpec.Agents.Tools.AnswerNotification
    alias CodeMySpec.Notifications.QuestionRequest

    params = %{notification_id: ctx.request.id, answer: "Yes, ship it.", basis: "record"}

    assert {:error, message} = AnswerNotification.call(params, %{scope: ctx.scope})
    assert message =~ "answer text must name a project"
    assert message =~ "issue's title or first eight ID characters"
    assert message =~ "working copy's"
    assert message =~ "ready story without an epic"
    assert message =~ "resolved Question on the asker's story"
    assert message =~ "at least eight characters"
    assert message =~ "escalated to the user"
    assert message =~ "remains unanswered"
    assert message =~ "retry"

    escalated = CodeMySpec.Repo.get!(QuestionRequest, ctx.request.id)
    assert escalated.holder == "user"
    refute escalated.status == "answered"

    assert {:error, ^message} = AnswerNotification.call(params, %{scope: ctx.scope})

    {:ok, question} = Questions.create_question(ctx.scope, ctx.story.id, %{text: "Ship now?"})
    {:ok, resolved} = Questions.resolve_question(ctx.scope, question, "Yes.")
    answer = "Yes, see #{String.slice(resolved.id, 0, 8)}."

    assert {:ok, confirmation} =
             AnswerNotification.call(%{params | answer: answer}, %{scope: ctx.scope})

    assert confirmation =~ "Answered."
    assert CodeMySpec.Repo.get!(QuestionRequest, ctx.request.id).status == "answered"
  end

  test "citing a resolved Question still open is not enough", ctx do
    {:ok, question} =
      Questions.create_question(ctx.scope, ctx.story.id, %{text: "Ship this cycle?"})

    short_id = String.slice(question.id, 0, 8)
    answer = "Yes, decided (see #{short_id})."

    assert {:error, :not_recorded} =
             MainAgent.answer_question(ctx.scope, ctx.request.id, answer, basis: "record"),
           "an open, unresolved Question counted as a record"
  end

  test "citing a resolved Question from a different story is not enough", ctx do
    other_story = story_fixture(ctx.scope)
    {:ok, question} = Questions.create_question(ctx.scope, other_story.id, %{text: "Unrelated?"})
    {:ok, resolved} = Questions.resolve_question(ctx.scope, question, "Yes.")

    short_id = String.slice(resolved.id, 0, 8)
    answer = "Yes, decided (see #{short_id})."

    assert {:error, :not_recorded} =
             MainAgent.answer_question(ctx.scope, ctx.request.id, answer, basis: "record"),
           "a resolved Question on an unrelated story counted as this story's record"
  end
end

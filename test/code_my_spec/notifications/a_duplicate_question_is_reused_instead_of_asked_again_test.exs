defmodule CodeMySpec.Notifications.ADuplicateQuestionIsReusedInsteadOfAskedAgainTest do
  @moduledoc """
  Issue fe683550: agents on the same story kept asking a question that was
  already open, or had just been answered, because nothing before
  `create_agent_question_request/4` checked for one. The repro included a
  re-ask 58 seconds after the first had already been answered.

  `create_agent_question_request/4` now looks for a pending or just-answered
  request with the same `questions` on the same story before inserting a new
  row, and returns that one instead.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    story = story_fixture(scope)

    %{scope: scope, copy_id: copy.id, story: story}
  end

  defp agent_with_active_task(ctx) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        working_copy: "/tmp/dedup-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy_id
      })

    AgentPresence.present(agent)

    {:ok, agent} =
      TaskOwner.add_task(ctx.scope, agent, %{status: :active, story_id: ctx.story.id})

    agent
  end

  defp attrs_for(question_text) do
    %{
      "title" => "Claude has a question",
      "questions" => [
        %{"question" => question_text, "header" => nil, "multiSelect" => false, "options" => []}
      ]
    }
  end

  defp requests_for_story(story_id) do
    Repo.all(from q in QuestionRequest, where: q.story_id == ^story_id)
  end

  test "a second identical ask on the same story, still pending, reuses it", ctx do
    asker = agent_with_active_task(ctx)
    other_asker = agent_with_active_task(ctx)

    {:ok, first} =
      Notifications.create_agent_question_request(
        ctx.scope,
        asker.id,
        attrs_for("Which refund window applies?")
      )

    assert first.status == "pending"

    {:ok, second} =
      Notifications.create_agent_question_request(
        ctx.scope,
        other_asker.id,
        attrs_for("Which refund window applies?")
      )

    assert second.id == first.id,
           "a second, still-open ask for the same story and question text got its own row"

    assert length(requests_for_story(ctx.story.id)) == 1,
           "a duplicate ask inserted a second row instead of reusing the open one"
  end

  test "an identical ask shortly after the first was answered reuses the answered one", ctx do
    first_asker = agent_with_active_task(ctx)

    {:ok, first} =
      Notifications.create_agent_question_request(
        ctx.scope,
        first_asker.id,
        attrs_for("Which refund window applies?")
      )

    {:ok, _} =
      Notifications.answer_question_request(first.id, %{
        "Which refund window applies?" => "30 days"
      })

    second_asker = agent_with_active_task(ctx)

    {:ok, second} =
      Notifications.create_agent_question_request(
        ctx.scope,
        second_asker.id,
        attrs_for("Which refund window applies?")
      )

    assert second.id == first.id,
           "a re-ask shortly after the first was answered got a brand new, unanswered row"

    assert second.status == "answered"
    assert second.answers == %{"Which refund window applies?" => "30 days"}
    assert length(requests_for_story(ctx.story.id)) == 1
  end

  test "a different question on the same story is not deduped", ctx do
    first_asker = agent_with_active_task(ctx)
    second_asker = agent_with_active_task(ctx)

    {:ok, first} =
      Notifications.create_agent_question_request(
        ctx.scope,
        first_asker.id,
        attrs_for("Which refund window applies?")
      )

    {:ok, second} =
      Notifications.create_agent_question_request(
        ctx.scope,
        second_asker.id,
        attrs_for("Does this cover international orders?")
      )

    refute second.id == first.id,
           "a genuinely different question on the same story was folded into the first one's row"

    assert length(requests_for_story(ctx.story.id)) == 2
  end

  test "the same question on a different story is not deduped", ctx do
    other_story = story_fixture(ctx.scope)

    asker = agent_with_active_task(ctx)

    {:ok, other_asker} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        working_copy: "/tmp/dedup-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy_id
      })

    AgentPresence.present(other_asker)

    {:ok, other_asker} =
      TaskOwner.add_task(ctx.scope, other_asker, %{status: :active, story_id: other_story.id})

    {:ok, first} =
      Notifications.create_agent_question_request(
        ctx.scope,
        asker.id,
        attrs_for("Which refund window applies?")
      )

    {:ok, second} =
      Notifications.create_agent_question_request(
        ctx.scope,
        other_asker.id,
        attrs_for("Which refund window applies?")
      )

    refute second.id == first.id,
           "the same wording on an unrelated story was folded into the first story's question"
  end
end

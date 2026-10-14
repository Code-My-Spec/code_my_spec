defmodule CodeMySpec.Notifications.AnAnsweredQuestionIsVisibleToCheckAnswerTest do
  @moduledoc """
  Issue 6c0238c0: a closer read of the original "answered question does not
  wake the asker" report (the issue's own later corrections) narrowed the
  real claim to something more specific - an agent that was awake and polled
  `check_answer` by the question's own id was told `pending` even though the
  answer had already been recorded and reported as a success.

  The suspected mechanism, per the issue: "whether answer_notification writes
  a notification record while check_answer reads the question/answer pair
  the question was created with - one store written, a different one read."

  This pins the write (`Notifications.answer_question_request/3`, what every
  answering path settles through) against the read `check_answer` itself
  performs (`CheckAnswer.execute/2`), back to back with no wake or nudge in
  between, to confirm they agree.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.Notifications
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, asker} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: true,
        working_copy: "/tmp/visible-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(asker)

    %{
      scope: scope,
      asker: asker,
      asker_frame: %Frame{assigns: %{current_scope: scope, agent_id: asker.id}}
    }
  end

  defp ask(ctx, text) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        ctx.asker.id,
        %{
          "title" => "a question",
          "questions" => [%{"question" => text, "options" => []}],
          "holder" => "main_agent"
        },
        nil
      )

    request
  end

  test "check_answer sees the answer immediately after the question is answered", ctx do
    request = ask(ctx, "Which refund window applies?")

    {:ok, answered} =
      Notifications.answer_question_request(
        request.id,
        %{"Which refund window applies?" => "30 days"},
        answered_by: "main_agent"
      )

    assert answered.status == "answered"

    {:reply, checked, _frame} =
      CheckAnswer.execute(%{question_id: request.id}, ctx.asker_frame)

    text = checked.content |> List.first() |> Map.get("text", "")

    refute text =~ ~r/still (waiting|pending)/i,
           """
           check_answer reported the question as still pending immediately after
           the answer was recorded - the write is not visible to the read.

           check_answer's reply:
           #{text}
           """

    assert text =~ "30 days"
  end
end

defmodule CodeMySpec.Agents.AnAnswerReachesAnAskerThatIsComingBackTest do
  @moduledoc """
  2026-10-15: John answered Metric Flow's coder's story 57 question at 23:44,
  a minute after a promote restarted the server. The idle coder was not present
  yet, so no turn was admitted and the answer was recorded nowhere: the coder
  waited on a question that had been answered. An answer that cannot open a
  turn now lands on the asker's thread, as a released blocker's notice does.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Notifications
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.AgentPresence

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    :ok = Fixtures.install_recording_agent_transport(ctx)
    coder = Fixtures.running_agent(ctx.scope, role: "coding", continuous: true)
    %{coder: coder}
  end

  test "an idle asker that is not present yet finds the answer on its thread", ctx do
    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        ctx.coder.id,
        %{
          "title" => "YouTube data",
          "holder" => "user",
          "questions" => [%{"question" => "Where should clients see it?", "options" => []}]
        },
        nil
      )

    :ok = AgentPresence.absent(ctx.coder)
    before = Fixtures.messages_to_agent(ctx.scope, ctx.coder.id)

    {:ok, _} =
      Notifications.answer_question_request(request.id, %{
        "Where should clients see it?" => "On the dashboard"
      })

    await_dispatches()

    assert [answer] = Fixtures.messages_to_agent(ctx.scope, ctx.coder.id) -- before
    assert answer =~ "The user answered your question"
    assert answer =~ "On the dashboard"
  end

  for {author, label} <- [
        {"main_agent", "The main agent"},
        {"product_agent", "The product agent"}
      ] do
    @answer_author author
    @answer_label label
    test "an answer from #{author} keeps its authorship in delivery and resume details", ctx do
      {:ok, request} =
        Notifications.create_agent_question_request(
          ctx.scope,
          ctx.coder.id,
          %{
            "title" => "Answer attribution",
            "holder" => @answer_author,
            "questions" => [%{"question" => "Where?", "options" => []}]
          },
          nil
        )

      :ok = AgentPresence.absent(ctx.coder)
      before = Fixtures.messages_to_agent(ctx.scope, ctx.coder.id)

      assert {:ok, answered} =
               Notifications.answer_question_request(
                 request.id,
                 %{"Where?" => "On the dashboard"},
                 answered_by: @answer_author
               )

      assert answered.answered_by == @answer_author
      await_dispatches()

      assert [notice] = Fixtures.messages_to_agent(ctx.scope, ctx.coder.id) -- before
      assert notice =~ @answer_label
      refute notice =~ "The user answered"
      assert notice =~ "On the dashboard"
      detail = Notifications.answer_detail(request.id)
      assert detail =~ @answer_label
      refute detail =~ "The user answered"
    end
  end

  test "only a user answer notifies the agent that escalated the question", ctx do
    handler = {__MODULE__, make_ref()}
    event = [:code_my_spec, :notifications, :escalated_answer_reached]

    :ok =
      :telemetry.attach(
        handler,
        event,
        &__MODULE__.capture_escalated_answer/4,
        {self(), ctx.coder.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for author <- ["main_agent", "product_agent"] do
      {:ok, request} =
        Notifications.create_agent_question_request(
          ctx.scope,
          ctx.coder.id,
          %{
            "title" => "Escalated answer attribution",
            "holder" => "main_agent",
            "questions" => [%{"question" => "Where?", "options" => []}]
          },
          nil
        )

      {:ok, _} =
        CodeMySpec.Agents.Main.QuestionsRepository.hand_to_user(
          request.id,
          "Needs a decision"
        )

      assert {:ok, _} =
               Notifications.answer_question_request(
                 request.id,
                 %{"Where?" => "On the dashboard"},
                 answered_by: author
               )

      refute_receive {:escalated_answer, _}
    end

    await_dispatches()
  end

  test "a user answer notifies the agent that escalated the question", ctx do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :notifications, :escalated_answer_reached],
        &__MODULE__.capture_escalated_answer/4,
        {self(), ctx.coder.id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, request} =
      Notifications.create_agent_question_request(
        ctx.scope,
        ctx.coder.id,
        %{
          "title" => "User answer attribution",
          "holder" => "main_agent",
          "questions" => [%{"question" => "Where?", "options" => []}]
        },
        nil
      )

    {:ok, _} =
      CodeMySpec.Agents.Main.QuestionsRepository.hand_to_user(
        request.id,
        "Needs a decision"
      )

    assert {:ok, _} =
             Notifications.answer_question_request(
               request.id,
               %{"Where?" => "On the dashboard"},
               answered_by: "user"
             )

    assert_receive {:escalated_answer, text}
    assert text =~ "The user answered question #{request.id}"
    assert text =~ "On the dashboard"
    await_dispatches()
  end

  def capture_escalated_answer(
        _event,
        _measurements,
        %{asker: %{id: asker_id}, text: text},
        {pid, asker_id}
      ) do
    send(pid, {:escalated_answer, text})
  end

  def capture_escalated_answer(_event, _measurements, _meta, _config), do: :ok

  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end
end

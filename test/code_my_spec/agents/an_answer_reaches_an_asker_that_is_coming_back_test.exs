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

  defp await_dispatches do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, 5_000 end)
  end
end

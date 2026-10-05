defmodule CodeMySpec.Agents.AnIgnoredOfferOfQuestionsIsNotMadeAgainTest do
  @moduledoc """
  b7a705ee: main was offered "questions are waiting" four times in six minutes
  for one it believed it had escalated, and every turn read "no change". The
  graph-work damper allows five repeats and then re-offers after ten minutes,
  because claimability can change while the set does not. A question does not
  become answerable by waiting, so an unchanged set of them is held after one
  decline and offered again only when the set moves.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The first offer is the project's own: settling the graph reconsiders every
  # running agent in a background task, and main, holding a question, is
  # offered it. Each test then drives what main does with that offer.
  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    main = agent(ctx.scope, "main")
    # Product's questions go to main, as on the project where this was measured.
    asker = agent(ctx.scope, "product")
    question = question(ctx.scope, asker, "Which way?")

    :ok = GraphWatcher.settle(ctx.scope)
    :ok = Fixtures.drain_background_work()

    Map.merge(ctx, %{main: main, asker: asker, question: question})
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/questions-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    {:ok, _conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  defp question(scope, asker, text) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        asker.id,
        %{
          "title" => text,
          "questions" => [%{"question" => text, "options" => []}],
          "holder" => MainAgent.holder_for(scope, asker.id)
        },
        nil
      )

    request
  end

  defp reload(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)
    fresh
  end

  defp offers(agent), do: Offers.list_for_agent(agent.id)

  # Counted in offer rows rather than read off the call's answer: a graph
  # change can reconsider main in a background task at the same moment, and
  # whichever of the two reserves the turn, it is one offer made.
  defp offered?(scope, agent) do
    before = length(offers(agent))
    _ = Work.request_turn_if_runnable(scope, reload(scope, agent), :test)
    :ok = Fixtures.drain_background_work()
    length(offers(agent)) > before
  end

  # The offered turn as the real events end it: started, then ended with
  # nothing claimed.
  defp ignored(scope, agent) do
    {:ok, agent} =
      AgentsRepository.update_agent(scope, reload(scope, agent), %{
        turn_started_at: nil,
        work_request_id: nil,
        work_requested_at: nil
      })

    {:ok, _agent} =
      Work.record_decline(scope, agent, DateTime.add(DateTime.utc_now(), -30, :second))
  end

  test "main is offered the questions it holds", ctx do
    assert [%{subject_type: "questions"}] = offers(ctx.main)

    id = ctx.main.id
    assert_receive {:work_turn_requested, ^id, _ref, prompt}, 2_000

    assert prompt =~ "escalate_question",
           "the offer named answering but not passing a question up"

    assert prompt =~ "never re-asked with `ask_user_question`"
  end

  test "questions ignored once are not offered again while unchanged", ctx do
    ignored(ctx.scope, ctx.main)

    refute offered?(ctx.scope, ctx.main),
           "main was re-offered the same questions it had just ignored (b7a705ee)"

    assert length(offers(ctx.main)) == 1
  end

  test "a long-held unchanged set stays held", ctx do
    ignored(ctx.scope, ctx.main)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, reload(ctx.scope, ctx.main), %{
        declined_offer_at: DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)
      })

    refute offered?(ctx.scope, ctx.main),
           "an unchanged set of questions came back on the graph-work window"
  end

  test "a new question is a new offer", ctx do
    ignored(ctx.scope, ctx.main)
    question(ctx.scope, ctx.asker, "Which colour?")

    assert offered?(ctx.scope, ctx.main),
           "a question raised after the decline was held back with the old ones"
  end

  test "an escalated question is no longer main's work", ctx do
    {:ok, _} = MainAgent.escalate_question(ctx.scope, ctx.question.id, "it is theirs to decide")
    ignored(ctx.scope, ctx.main)

    refute offered?(ctx.scope, ctx.main)
  end
end

defmodule CodeMySpec.Agents.AStuckLoopGoesQuietTest do
  @moduledoc """
  A continuous agent holding a task it cannot close is told once, not forever.

  `keep_working/2`'s `:continuing` decision was deliberately exempt from
  `stuck?/3` — "a continuation is not a repeat", because closing one task and
  picking up the next changes the menu every time, and five *different*
  successful turns must never look like the same failure repeated five times.
  That reasoning holds exactly as long as the menu keeps changing.

  It does not hold for a task blocked on someone else's work: `qa_complete`
  waiting on a coding fix renders the identical menu turn after turn, forever,
  because nothing about it ever changes from this agent's side. Watched live
  2026-09-11: a QA agent was told "Work of your kind is available" and "Your
  turn is done and the loop is still running" nine times in 108 seconds over
  the same story, each reply "no new information, standing by" answered within
  seconds by the same message again, until it tapped out rather than keep
  answering it.

  The fix keys `stuck?` on the rendered message itself rather than the
  constant `:continuing` atom (or nothing, for `wake/2`'s project-wide fan-out,
  which had no throttle at all). Genuine progress changes the text every time
  and never trips it; an unchanging menu does, after the same five repeats
  every other class of message already gets.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

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
        continuous: true,
        working_copy: "/tmp/stuck-loop-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn ->
      :persistent_term.erase({StopDecision, :continuing, agent.id})
      :persistent_term.erase({StopDecision, :wake, agent.id})
    end)

    %{scope: scope, agent: agent}
  end

  defp holding(agent, task_id) do
    task = %CodeMySpec.Sessions.Task{
      id: task_id,
      status: :active,
      requirement_name: "qa_complete",
      started_at: DateTime.utc_now()
    }

    %{agent | tasks: [task]}
  end

  defp drain(acc \\ []) do
    receive do
      {:agent_dispatch, _id, _ref, message} -> drain([message | acc])
      {:agent_message, _id, message} -> drain([message | acc])
    after
      200 -> acc
    end
  end

  test "the same blocked task stops being repeated on deliver/2", ctx do
    stuck = holding(ctx.agent, Ecto.UUID.generate())

    for _ <- 1..9, do: StopDecision.deliver(ctx.scope, stuck, [])

    continuing = Enum.count(drain(), &String.contains?(&1, "loop is still running"))

    assert continuing > 0, "the agent must hear about its open task at least once"

    assert continuing <= 5,
           "nine identical stops delivered the same menu #{continuing} times; it has to " <>
             "go quiet after five, the same as every other repeated message"
  end

  test "a genuinely progressing loop is never silenced", ctx do
    for _ <- 1..9 do
      StopDecision.deliver(ctx.scope, holding(ctx.agent, Ecto.UUID.generate()), [])
    end

    continuing = Enum.count(drain(), &String.contains?(&1, "loop is still running"))

    assert continuing == 9,
           "a different task id each turn is a different menu each turn — closing one " <>
             "task and picking up the next must never be silenced as though it were a repeat"
  end

  test "the same blocked task stops being repeated on wake/2", ctx do
    stuck = holding(ctx.agent, Ecto.UUID.generate())

    for _ <- 1..9, do: StopDecision.wake(ctx.scope, stuck)

    woken = Enum.count(drain(), &String.contains?(&1, "Work of your kind is available"))

    assert woken > 0, "the agent must be woken about its open task at least once"

    assert woken <= 5,
           "nine identical project-wide wakes delivered the same menu #{woken} times; " <>
             "wake/2 had no throttle at all before this"
  end
end

defmodule CodeMySpec.MainAgent.TheCadenceDeliversATurnTest do
  @moduledoc """
  The cadence is for a continuous main only (John): each tick gives it exactly
  one turn, work or no work, carrying the check-in and its own work offer.

  `2c34da87`: the tick fired and no turn arrived. Then step 4b held the
  non-continuous push, so nothing arrived for anyone; this is the converged
  turn that replaced both.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.MainAgent
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Cadence
  alias CodeMySpec.MainAgent.CheckInReport
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Staffing
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Main lives on the main checkout; the tick finds it there, as stall notices do.
  setup %{scope: scope} do
    {:ok, _} = CodeMySpec.WorkingCopies.designate_main(scope, scope.active_working_copy_id)
    :ok
  end

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      Wake.telemetry_event(),
      fn _event, _measurements, meta, _config -> send(test_pid, {:wake, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp agent(scope, role, attrs \\ %{}) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            role: role,
            status: :running,
            continuous: true,
            provider: "anthropic",
            engine: :alloy,
            working_copy: "/tmp/cadence-#{System.unique_integer([:positive])}",
            working_copy_id: scope.active_working_copy_id
          },
          attrs
        )
      )

    agent
  end

  # Main-role work on the graph, settled so no graph pass offers it a turn
  # behind the test's back.
  defp kickoff(ctx) do
    ctx = ProjectStateFixtures.apply_project_kickoff(ctx)
    :ok = GraphWatcher.settle(ctx.scope)
    ctx
  end

  defp settled(scope) do
    :ok = GraphWatcher.settle(scope)
    refute_received {:work_turn_requested, _id, _ref, _prompt}, "a turn before the tick"
  end

  # The real tick, then a call to the same process: it answers only after the
  # tick is handled, and the recording transport sends from inside it.
  defp tick(scope) do
    {:ok, pid} = Cadence.start_link(scope)
    send(pid, :check_in)
    assert %DateTime{} = Cadence.last_check(scope)
  end

  defp turn(%{id: id}) do
    assert_received {:work_turn_requested, ^id, _ref, prompt}
    refute_received {:work_turn_requested, _id, _ref, _prompt}, "a second turn on one tick"
    prompt
  end

  defp stalled(id) do
    %AgentWork{
      agent_id: id,
      role: :coding,
      working_copy_id: "copy-#{id}",
      agent_status: :running,
      idle?: false,
      blocked_reasons: [],
      problems: []
    }
  end

  describe "a continuous main" do
    test "with work gets one turn carrying the check-in and its work offer", ctx do
      ctx = kickoff(ctx)
      main = agent(ctx.scope, "main")
      _coding = agent(ctx.scope, "coding", %{continuous: false})
      assert Work.claimable_work(ctx.scope, main) != []
      settled(ctx.scope)

      tick(ctx.scope)

      prompt = turn(main)
      assert prompt =~ "Check-in."
      assert prompt =~ "#{main.id} (main) — you"
      assert prompt =~ "start_task"
      refute prompt =~ "The first is:"
      refute_received {:agent_message, _id, _text}
    end

    test "with no work still gets the check-in as its one turn", ctx do
      main = agent(ctx.scope, "main")
      assert Work.claimable_work(ctx.scope, main) == []
      settled(ctx.scope)

      tick(ctx.scope)

      prompt = turn(main)
      assert prompt =~ "Check-in."
      refute prompt =~ "start_task"
    end

    test "whose offer the damper holds gets the check-in without it", ctx do
      ctx = kickoff(ctx)
      main = agent(ctx.scope, "main")
      offer = Work.offer_fingerprint(ctx.scope, main, Work.claimable_work(ctx.scope, main))

      for _ <- 1..5 do
        {:ok, _} = Work.suppress_offer(ctx.scope, fetch!(ctx.scope, main.id), offer)
      end

      settled(ctx.scope)

      tick(ctx.scope)

      prompt = turn(main)
      assert prompt =~ "Check-in."
      refute prompt =~ "start_task"
    end

    test "mid-turn gets no second turn", ctx do
      main = agent(ctx.scope, "main", %{turn_started_at: DateTime.utc_now()})

      tick(ctx.scope)

      refute_received {:work_turn_requested, _id, _ref, _prompt}
      main_id = main.id
      refute_received {:wake, %{agent_id: ^main_id, event: :work_offer}}
    end

    test "waiting on its own analysis run is left to it", ctx do
      main = agent(ctx.scope, "main")

      {:ok, _run} =
        RunsRepository.start_run(ctx.scope, %{
          source: "spex",
          kind: :full,
          status: :running,
          requested_by: %{kind: "mcp_tool", tool: "start_analysis", agent_id: main.id}
        })

      tick(ctx.scope)

      refute_received {:work_turn_requested, _id, _ref, _prompt}
      main_id = main.id

      assert_received {:wake,
                       %{agent_id: ^main_id, event: :cadence, result: {:hold, :analysis_runs}}}
    end

    test "hears a newly stalled teammate in the turn, not as a second message", ctx do
      main = agent(ctx.scope, "main")

      MainAgent.cadence_check_in(ctx.scope, %Digest{work: [stalled("a1b2c3d4")]}, [
        stalled("a1b2c3d4")
      ])

      prompt = turn(main)
      assert prompt =~ "Needs you:"
      assert prompt =~ "a1b2c3d4 (new) — STALLED"
      refute_received {:wake, %{event: :teammate_stalled}}
    end

    test "mid-turn still hears a newly stalled teammate on its own", ctx do
      # `notify_main` finds main through the designated main copy.
      {:ok, _} = Staffing.designate_main(ctx.scope, ctx.scope.active_working_copy_id)
      main = agent(ctx.scope, "main", %{turn_started_at: DateTime.utc_now()})

      MainAgent.cadence_check_in(ctx.scope, %Digest{work: [stalled("a1b2c3d4")]}, [
        stalled("a1b2c3d4")
      ])

      main_id = main.id
      refute_received {:work_turn_requested, _id, _ref, _prompt}
      assert_received {:wake, %{agent_id: ^main_id, event: :teammate_stalled, result: :ok}}
      assert_receive {:agent_message, ^main_id, text}, 2_000
      assert text =~ "a1b2c3d4"
    end

    test "is still reached at once by a teammate's question", ctx do
      main = agent(ctx.scope, "main")
      coder = agent(ctx.scope, "coding", %{continuous: false})

      {:ok, request} =
        Notifications.create_agent_question_request(
          ctx.scope,
          coder.id,
          %{
            "title" => "Blocked",
            "holder" => "main_agent",
            "questions" => [%{"question" => "Which way?", "options" => []}]
          },
          nil
        )

      :ok = MainAgent.question_raised(ctx.scope, request)

      assert turn(main) =~ "answer_notification"
    end
  end

  test "a non-continuous main gets nothing from the tick", ctx do
    main = agent(ctx.scope, "main", %{continuous: false})

    tick(ctx.scope)

    refute_received {:work_turn_requested, _id, _ref, _prompt}
    refute_received {:agent_message, _id, _text}
    main_id = main.id

    assert_received {:wake,
                     %{agent_id: ^main_id, event: :cadence, result: {:hold, :not_continuous}}}
  end

  test "a stood-down project's tick gives main nothing", ctx do
    main = agent(ctx.scope, "main")
    :ok = Cadence.stand_down(ctx.scope)
    on_exit(fn -> Cadence.resume(ctx.scope) end)
    # Only what the tick does: creating main on the main checkout is its own event.
    flush()

    tick(ctx.scope)

    refute_received {:work_turn_requested, _id, _ref, _prompt}
    main_id = main.id
    # The tick's own wake. Creating main on the main checkout is an event of its
    # own, answered asynchronously, and is not what this asserts.
    refute_received {:wake, %{agent_id: ^main_id, event: :cadence}}
  end

  describe "the turn's text" do
    defp question(holder) do
      %OpenQuestion{
        id: "q-#{holder}",
        holder: holder,
        questions: [%{"question" => "Ask #{holder}?"}],
        agent_id: "asker",
        agent_role: :coding
      }
    end

    test "leads with what waits on main, then the fleet" do
      digest = %Digest{
        work: [%{stalled("me") | role: :main}, stalled("s1")],
        questions: [question("main_agent"), question("user")]
      }

      text = CheckInReport.render(digest, self: "me", work?: true, new_stalls: [])

      assert text =~ "question q-main_agent from the coding agent asker: Ask main_agent?"
      assert text =~ "answer_notification"
      assert text =~ "s1 on working copy copy-s1 — STALLED"
      assert text =~ "me (main) — you"
      assert text =~ "s1 (coding) — stalled, above"
      assert text =~ "questions waiting on others: 1"

      order =
        Enum.map(["Needs you:", "Your work:", "agents:", "questions waiting"], &pos(text, &1))

      assert order == Enum.sort(order)
      refute text =~ "yours to answer"
    end

    test "without work or anything waiting on main, says so plainly" do
      text = CheckInReport.render(%Digest{}, work?: false)

      assert text =~ "Nothing needs you"
      refute text =~ "Needs you:"
      refute text =~ "Your work:"
      assert text =~ "questions: none open."
    end

    defp pos(text, needle) do
      {at, _} = :binary.match(text, needle)
      at
    end
  end

  defp fetch!(scope, id) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, id)
    agent
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end

defmodule CodeMySpec.Analysis.AnUnchangedFindingStopsAnnouncingItselfTest do
  @moduledoc """
  A run that says what the last one said does not wake anybody.

  `AnalysisReport.deliver/3` fired on every completed run, and every stop hook
  re-enqueues credo, so one unchanged finding announced itself once a turn
  forever. The agent has nothing to do about it — the tree did not change — so
  it answers "already covered, no action", ends the turn, and the next stop
  starts the cycle again.

  The cost is not the wasted turn, it is which agent pays it. A main agent on
  the math project spent four consecutive turns on the same credo alert and
  never reached `work_dispatched`, the requirement that puts story work in
  flight, so the whole fleet sat behind one repeating notification. It
  diagnosed its own livelock and filed `bffa0da7` before anyone looked at it:
  "no file was edited and no new analysis was requested between repeats, so
  nothing about the tree changed between alerts".

  `Signatures.delta/2` already computed this for the reconcile log line. The
  announcement is now gated on the same answer.

  ## What counts as new

  `new` is empty both when nothing changed and when problems only went away,
  and neither is worth a wake: the digest counts what remains, which the agent
  has already been told. An absent baseline reads as all-new, so a first run —
  and a run whose predecessor predates signature recording — both still
  announce, which is the safe direction for this to be wrong in.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Problems.Problem
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        continuous: true,
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/unchanged-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    %{scope: scope, copy: copy}
  end

  defp requested_by(attrs, nil), do: attrs

  defp requested_by(attrs, agent_id),
    do: Map.put(attrs, :requested_by, %{"kind" => "mcp_tool", "agent_id" => agent_id})

  defp drain_dispatches do
    receive do
      {:agent_dispatch, _, _, _} -> drain_dispatches()
    after
      300 -> :ok
    end
  end

  defp problem(path) do
    %Problem{
      severity: :error,
      source: "credo",
      source_type: :static_analysis,
      file_path: path,
      message: "boom",
      category: "readability"
    }
  end

  defp sweep(scope, problems, opts \\ []) do
    # Earlier notifications have completed their model turn before another
    # analysis report arrives. The recording wire does not supply that evidence.
    waiting =
      Repo.all(
        from e in Mailbox.Entry,
          join: a in Agent,
          on: a.id == e.agent_id,
          where: a.project_id == ^scope.active_project_id and e.state == :claimed,
          select: e
      )

    for entry <- waiting do
      {:ok, _} = Mailbox.register(scope, entry.agent_id, "report-engine")
      {:ok, _} = Mailbox.consume(scope, entry.agent_id, entry.delivery_ref, "report-engine")
      {:ok, _} = Mailbox.finish(scope, entry.agent_id, entry.delivery_ref, "report-engine")
    end

    attrs = requested_by(%{source: "credo", kind: :full}, Keyword.get(opts, :requested_by))

    {:ok, run} = RunsRepository.start_run(scope, attrs)

    {:ok, _finished} =
      Reconciler.reconcile(scope, run, %{
        problems: problems,
        output: "done",
        exit_status: 1,
        stats: %{}
      })

    :ok
  end

  test "the first run announces and an identical second one does not", ctx do
    sweep(ctx.scope, [problem("lib/a.ex")])

    assert_receive {:agent_dispatch, _id, _ref, message}, 2_000
    assert message =~ "credo run finished"
    drain_dispatches()

    sweep(ctx.scope, [problem("lib/a.ex")])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end

  test "a finding that was not there before still announces", ctx do
    sweep(ctx.scope, [problem("lib/a.ex")])
    assert_receive {:agent_dispatch, _id, _ref, _message}, 2_000
    drain_dispatches()

    sweep(ctx.scope, [problem("lib/a.ex"), problem("lib/b.ex")])

    assert_receive {:agent_dispatch, _id, _ref, message}, 2_000

    assert message =~ "2 blocking problems",
           """
           A run that found something new said nothing.

           Gating on the delta must not silence a real change — that would
           trade a loop for a miss, and a miss has no symptom at all.
           """
  end

  # A reply to a question the agent asked is a reply, and silence there is not
  # quiet — it is a hang.
  #
  # Measured 2026-09-22, within the hour of the gate above shipping: coding
  # started a spex sweep, said it would wait for the result rather than poll,
  # and stopped. The sweep found the same criteria failing for a different
  # reason, so the signatures — `file:line criterion-name`, which do not carry
  # the error — were unchanged, and the answer was swallowed. It held its task
  # and waited twenty-two minutes for a message that was never coming.
  test "a run the agent asked for answers even when nothing changed", ctx do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        continuous: true,
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/asked-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    AgentPresence.present(agent)

    sweep(ctx.scope, [problem("lib/a.ex")])
    assert_receive {:agent_dispatch, _id, _ref, _message}, 2_000
    # `deliver/3` tells every report-role agent on the copy, and this test adds
    # a second one — so an undrained mailbox lets sweep one's dispatch satisfy
    # the assertion for sweep two, and the test passes with the gate removed.
    drain_dispatches()

    sweep(ctx.scope, [problem("lib/a.ex")], requested_by: agent.id)

    assert_receive {:agent_dispatch, _id, _ref, message}, 2_000

    assert message =~ "credo run finished",
           """
           A run the agent started did not answer it.

           The agent is not being notified of something; it is waiting on a
           reply to its own request, with its task held open until one lands.
           """
  end

  # A clean run is silence to the room and an answer to whoever asked.
  #
  # `digest/2` returns nil for a tree with no error-severity problems, and
  # `deliver/4` used to drop the delivery entirely on that — so a green run told
  # nobody, including the agent that had started it and said it would wait for
  # the result. Measured on the math project 2026-09-22: a coding agent held an
  # open `bdd_specs_passing` task for 25 minutes over a spex run that had come
  # back green, and `Work.runnable_state?/1` skips an agent holding a task, so
  # nothing in the system could reach it. A human had to say "it was green".
  test "a clean run answers the agent that asked for it", ctx do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        continuous: true,
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/asker-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    AgentPresence.present(agent)

    sweep(ctx.scope, [], requested_by: agent.id)

    assert_receive {:agent_dispatch, id, _ref, message}, 2_000

    assert id == agent.id, "the answer goes to the agent that started the run"

    assert message =~ "no blocking problems",
           """
           A run the agent started came back green and said nothing.

           Silence is the right answer to a room that did not ask. To the agent
           waiting on this specific run it is indistinguishable from a run that
           never happened, and it will wait on it holding a task.
           """
  end

  # The other half of criterion 3046, which this must not break.
  test "a clean run still says nothing to an agent that did not ask", ctx do
    sweep(ctx.scope, [])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end

  # Problems going away is a change, and deliberately not one worth a wake: the
  # digest counts what remains, and the agent has already been told about it.
  test "a run that only cleared findings does not announce", ctx do
    sweep(ctx.scope, [problem("lib/a.ex"), problem("lib/b.ex")])
    assert_receive {:agent_dispatch, _id, _ref, _message}, 2_000
    drain_dispatches()

    sweep(ctx.scope, [problem("lib/a.ex")])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end
end

defmodule CodeMySpec.Analysis.AnUnchangedFindingStopsAnnouncingItselfTest do
  @moduledoc """
  A run that says what the last one said does not wake anybody.

  `AgentReport.deliver/3` fired on every completed run, and every stop hook
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
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Problems.Problem
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

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, _agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/unchanged-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, copy: copy}
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

  defp sweep(scope, problems) do
    {:ok, run} = RunsRepository.start_run(scope, %{source: "credo", kind: :full})

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

    sweep(ctx.scope, [problem("lib/a.ex")])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end

  test "a finding that was not there before still announces", ctx do
    sweep(ctx.scope, [problem("lib/a.ex")])
    assert_receive {:agent_dispatch, _id, _ref, _message}, 2_000

    sweep(ctx.scope, [problem("lib/a.ex"), problem("lib/b.ex")])

    assert_receive {:agent_dispatch, _id, _ref, message}, 2_000

    assert message =~ "2 problems",
           """
           A run that found something new said nothing.

           Gating on the delta must not silence a real change — that would
           trade a loop for a miss, and a miss has no symptom at all.
           """
  end

  # Problems going away is a change, and deliberately not one worth a wake: the
  # digest counts what remains, and the agent has already been told about it.
  test "a run that only cleared findings does not announce", ctx do
    sweep(ctx.scope, [problem("lib/a.ex"), problem("lib/b.ex")])
    assert_receive {:agent_dispatch, _id, _ref, _message}, 2_000

    sweep(ctx.scope, [problem("lib/a.ex")])

    refute_receive {:agent_dispatch, _id, _ref, _message}, 500
  end
end

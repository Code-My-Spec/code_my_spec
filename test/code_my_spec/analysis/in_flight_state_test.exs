defmodule CodeMySpec.Analysis.InFlightStateTest do
  @moduledoc """
  "Nothing is running" and "nobody is watching" are different answers.

  `in_flight/1` returned `[]` for both: a project with no entry in
  `Analysis.Registry` — no server started, or a build without the Analysis
  subtree — is untracked, and folding that into idle renders absent information
  as good news.

  It cost a diagnosis in `998f4d93`. A test tried to settle the pipeline before
  comparing two stop decisions, waiting on `runs_in_flight?/1`; the wait
  returned instantly because the project was untracked, settled nothing, and the
  flake stayed at the same rate. The wait looked like it worked.

  It matters beyond that test. `Hooks.Stop.pending_analysis?/1` decides whether
  a stop is allowed as "analysis pending" on the same answer, and the message my
  own escalation prints — "No rerun is in flight. Stopping again enqueues one" —
  is a claim about the world that untracked cannot support.

  `in_flight/1` keeps its shape, because its callers are joining the list into
  a sentence and an untracked project has no sources to name either way. The
  three-way answer is for callers deciding what to *do*.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Harnesses

  describe "a project no server is tracking" do
    test "is untracked, not idle" do
      scope = full_scope_fixture()

      assert Analysis.in_flight_state(scope) == :untracked,
             "no registry entry means nobody would know if something were running"
    end

    test "still reports no sources, so message callers are unchanged" do
      scope = full_scope_fixture()

      assert Analysis.in_flight(scope) == []
    end
  end

  describe "a project served by a harness" do
    setup do
      scope = full_scope_fixture()
      {:ok, harness} = Harnesses.issue(scope, nil, label: "a working copy")
      scope = %{scope | active_harness_id: harness.id}

      # Registering an executor is what makes the project *served*. A harness
      # row on its own is not: `remote_executor/1` answers from the registry, so
      # a harness that has never joined is correctly untracked rather than idle
      # — which is the distinction being tested, one layer up.
      {:ok, _} =
        Registry.register(
          CodeMySpec.Analysis.HarnessRegistry,
          to_string(harness.id),
          :test
        )

      %{scope: scope, harness: harness}
    end

    test "with nothing running is idle rather than untracked", ctx do
      # The ledger is authoritative for a served project: a `:running` row is
      # the server's only record that it asked for something. No rows means
      # idle, and that is a real answer rather than an absence.
      assert Analysis.in_flight_state(ctx.scope) == :idle
    end

    test "a harness that has never joined is untracked, not idle" do
      unserved = full_scope_fixture()
      {:ok, harness} = Harnesses.issue(unserved, nil, label: "never joined")

      assert Analysis.in_flight_state(%{unserved | active_harness_id: harness.id}) ==
               :untracked,
             "a row is not a running process; nothing would report a run for it"
    end

    test "with a run recorded, names it", ctx do
      {:ok, _} = RunsRepository.start_run(ctx.scope, %{source: "spex", kind: :full})

      assert {:running, ["spex"]} = Analysis.in_flight_state(ctx.scope)
      assert Analysis.in_flight(ctx.scope) == ["spex"]
    end
  end

  describe "runs_in_flight?/1" do
    test "stays false for untracked, because nothing is known to be running" do
      # Deliberately unchanged. Its callers ask "should I wait for something",
      # and an untracked project has nothing to wait for — the fix is that a
      # caller who needs to know *why* can now ask.
      refute Analysis.runs_in_flight?(full_scope_fixture())
    end
  end
end

defmodule CodeMySpec.Problems.AnalyzerCouldNotRunTest do
  @moduledoc """
  "Has never completed" is true and says nothing, and the cause is already in
  the ledger.

  `6f89b278`. Three days of blocked stops on 22 stale spex findings belonging to
  stories the session never touched, with the hook advising "stop again and let
  the rerun replace these". The rerun could not replace them: `mix spex` aborted
  before booting, because the analyzer's test database — a partition the
  interactive session never touches — was two migrations behind.

  `Reconciler.fail/2` had written the analyzer's own words to `Run.output` the
  whole time, naming the database and the exact command for the right partition.
  Nothing read them back, so the agent went looking for a defect in another
  team's provisioning specs.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  defp problem(source) do
    %Problem{
      source: source,
      severity: :error,
      file_path: "test/spex/1011_a_thing/criterion_1_spex.exs",
      line: 12,
      message: "a stale finding from a story this session never touched"
    }
  end

  defp render(opts) do
    ProblemRenderer.render_stop_response(
      [problem("spex")],
      [],
      [stale_sources: ["spex"], last_ran: %{"spex" => nil}] ++ opts
    )
  end

  @migration_refusal """
  The test database `code_my_spec_test_had8804a9s` is 2 migration(s) behind.

  Pending: 20260811120000_conversation_messages_record_origin
  Run `MIX_TEST_PARTITION=had8804a9s MIX_ENV=test mix ecto.migrate` and try again.\
  """

  test "a source that never completed says why, in the analyzer's words" do
    text = render(run_failures: %{"spex" => @migration_refusal})

    assert text =~ "The analyzer could not run"

    assert text =~ "MIX_TEST_PARTITION=had8804a9s MIX_ENV=test mix ecto.migrate",
           "the command that ends the block was in `Run.output` for three days " <>
             "and nothing surfaced it. Naming the findings without naming this " <>
             "sends the reader to fix stories they never touched."

    assert text =~ "code_my_spec_test_had8804a9s",
           "which database it checked is the whole point — the agent migrated " <>
             "its own partition and stayed blocked, because that was never the " <>
             "database being checked"
  end

  test "the marker still says it never completed" do
    assert render(run_failures: %{"spex" => @migration_refusal}) =~ "has never completed"
  end

  test "a source that never completed and has no recorded reason renders as before" do
    text = render(run_failures: %{})

    assert text =~ "has never completed"
    refute text =~ "The analyzer could not run"
  end

  test "a source with an answer is untouched" do
    text =
      ProblemRenderer.render_stop_response([problem("credo")], [],
        stale_sources: ["credo"],
        last_ran: %{"credo" => DateTime.add(DateTime.utc_now(), -600, :second)},
        run_failures: %{"credo" => "should not be consulted"}
      )

    refute text =~ "The analyzer could not run",
           "this source answered; it is behind, which is a different condition " <>
             "and one that waiting fixes"
  end
end

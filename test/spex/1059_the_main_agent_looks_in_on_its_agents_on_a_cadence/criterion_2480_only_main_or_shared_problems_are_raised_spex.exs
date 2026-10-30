defmodule CodeMySpecSpex.Story1059.Criterion2480Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2480 — A teammate's own work-in-progress problem is counted, not
  raised; the same problem on the main working copy or on several copies at
  once is raised.

  A coder mid-change has failing tests; that is the work, and its team is on
  it. Raised every check-in, it trained main to skip the Needs-you block
  (2026-10-25: "9 needing attention", every one a team's own work). What is
  main's is a problem nobody's change explains: one on the main copy, or one
  that turns up on several copies at once and so came from somewhere they share.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @failing %{file_path: "test/my_app/accounts_test.exs", message: "Assertion with == failed"}

  spex "Only problems nobody's own change explains are raised", criterion: 2480 do
    scenario "one team's copy has a failing test" do
      given_ "a team copy with a failing test of its own", context do
        {copy_id, _scope} = staffed_copy(context, "/tmp/spex-2480-team", "team", @failing)
        {:ok, Map.put(context, :copy_id, copy_id)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "it is counted, not raised", context do
        refute Compact.needs_you(context.report) =~ context.copy_id,
               "A team's own failing test is its work, not main's.\n\n#{context.report}"

        assert context.report =~ ~r/1 cop(y|ies) with problems in progress/,
               "The problem is still counted, so main knows it exists.\n\n#{context.report}"

        {:ok, context}
      end
    end

    scenario "the same failing test turns up on two copies" do
      given_ "two team copies failing the same test", context do
        {a, _} = staffed_copy(context, "/tmp/spex-2480-a", "a", @failing)
        {b, _} = staffed_copy(context, "/tmp/spex-2480-b", "b", @failing)
        {:ok, Map.put(context, :copy_ids, [a, b])}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "it is raised", context do
        needs = Compact.needs_you(context.report)

        assert needs =~ "Assertion with == failed",
               """
               The same failure on two copies came from something they share,
               which no one team's change explains.

               #{context.report}
               """

        {:ok, context}
      end
    end

    scenario "the main copy has a failing test" do
      given_ "a failing test on the main working copy", context do
        {copy_id, _} = staffed_copy(context, "/tmp/spex-2480-main", "main", @failing)
        :ok = Fixtures.designate_main(context.scope, copy_id)
        {:ok, Map.put(context, :copy_id, copy_id)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "it is raised", context do
        assert Compact.needs_you(context.report) =~ context.copy_id,
               "A problem on the main copy is main's.\n\n#{context.report}"

        {:ok, context}
      end
    end
  end

  defp staffed_copy(context, root, label, problem) do
    reply = join_working_copy(context, root, label)
    scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
    _coder = Fixtures.running_agent(scope, role: "coding", working_copy: root)
    {:ok, _} = Fixtures.record_problem(scope, "exunit", problem)
    {reply.working_copy_id, scope}
  end
end

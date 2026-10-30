defmodule CodeMySpecSpex.Story1059.Criterion2474Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2474 — A problem in Needs you names the problem: source, file and
  message.

  "1 checkout problems" is a count that sends main to look. Every time it did,
  main read the copy's problems to learn whether the problem was its own, a
  teammate's half-finished work, or main's — and that answer is in the problem
  itself.
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

  spex "A raised problem says what it is", criterion: 2474 do
    scenario "the main copy has a failing test" do
      given_ "a failing test on the main copy", context do
        reply = join_working_copy(context, "/tmp/spex-2474-main", "main")
        :ok = Fixtures.designate_main(context.scope, reply.working_copy_id)
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        _coder =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2474-main")

        {:ok, _} =
          Fixtures.record_problem(scope, "exunit", %{
            file_path: "test/my_app/accounts_test.exs",
            message: "Assertion with == failed"
          })

        {:ok, context}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the entry names its source, file and message", context do
        needs = Compact.needs_you(context.report)

        assert needs =~
                 ~r/exunit[^\n]*test\/my_app\/accounts_test\.exs[^\n]*Assertion with == failed/,
               """
               The entry has to say what the problem is, so main can tell whose
               it is without opening the copy.

               Needs you:
               #{needs}
               """

        refute needs =~ ~r/\d+ checkout problems/,
               "A bare count is the line this replaces.\n\nNeeds you:\n#{needs}"

        {:ok, context}
      end
    end
  end
end

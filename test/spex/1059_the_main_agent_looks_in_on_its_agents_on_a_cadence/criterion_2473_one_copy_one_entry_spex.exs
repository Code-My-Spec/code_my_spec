defmodule CodeMySpecSpex.Story1059.Criterion2473Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 2473 — The coder and QA on one copy that report the same problem
  appear as one entry for that copy.

  A problem belongs to a working copy, not to an agent. Listed per agent, one
  failing test on a two-agent copy read as two things needing main, and a
  four-copy fleet read as nine (2026-10-25). Main then reads each and finds the
  same line four times over.
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

  spex "A copy's problem is one entry, not one per agent", criterion: 2473 do
    scenario "a coder and a QA share a copy with a failing test on main" do
      given_ "the main copy, staffed by a coder and a QA, has a failing test", context do
        reply = join_working_copy(context, "/tmp/spex-2473-main", "main")
        :ok = Fixtures.designate_main(context.scope, reply.working_copy_id)
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agents =
          for role <- ["coding", "qa"],
              do: Fixtures.running_agent(scope, role: role, working_copy: "/tmp/spex-2473-main")

        {:ok, _} =
          Fixtures.record_problem(scope, "exunit", %{
            file_path: "test/my_app/accounts_test.exs",
            message: "Assertion with == failed"
          })

        {:ok, context |> Map.put(:copy_id, reply.working_copy_id) |> Map.put(:agents, agents)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the copy is named once", context do
        needs = Compact.needs_you(context.report)
        occurrences = needs |> String.split(context.copy_id) |> length() |> Kernel.-(1)

        assert occurrences == 1,
               """
               The copy's one problem should be one entry. It appears #{occurrences} times.

               Needs you:
               #{needs}
               """

        {:ok, context}
      end

      then_ "and neither agent is listed for it", context do
        needs = Compact.needs_you(context.report)

        for agent <- context.agents do
          refute needs =~ agent.id,
                 """
                 The problem is the copy's, so the agents on it are not separate
                 entries for it.

                 Needs you:
                 #{needs}
                 """
        end

        {:ok, context}
      end
    end
  end
end

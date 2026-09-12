defmodule CodeMySpecSpex.Story1059.Criterion3332Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3332 — The wake-up says what is going on.

  Rule: the wake-up carries the answer, not the instruction to go and find it.

  A bare "time to check in" costs a turn before anything is known. The main
  agent wakes, calls `list_agent_work`, calls `check_machinery`, and only then
  starts thinking — and it does that seventy-two times a day, on a machine that
  is also running the agents it is checking on.

  Worse than the cost: a wake-up that says nothing is a wake-up an agent can
  reasonably dismiss. Told "look at your agents" with no reason to think
  anything is wrong, the cheapest correct-looking response is to glance and
  carry on, and the check-in becomes ceremony.

  ## What the digest has to carry

  Every agent and what it is doing — the criterion's own words. The scenario
  runs three agents in different states so that a digest which reported only the
  interesting one would fail: "what is going on" includes the ones that are
  fine, because that is what makes the one that is not stand out.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The check-in arrives with the answer in it" do
    scenario "three agents are in three different states" do
      given_ "a working agent, a quiet one and an idle one", context do
        reply = join_working_copy(context, "/tmp/spex-3332", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3332")

        working = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3332")

        {_agent, _task} =
          Fixtures.agent_task_fixture(scope, working, requirement_name: "implementation_file")

        :ok = Fixtures.agent_said(scope, working, "half done")

        quiet = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-3332")
        :ok = Fixtures.agent_said(scope, quiet, "starting")
        :ok = Fixtures.age_agent_messages(scope, quiet, 3 * 60 * 60)

        idle = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-3332")

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:agents, [working, quiet, idle])}
      end

      when_ "the main agent is woken", context do
        :ok = Fixtures.cadence_tick(context.scope)

        {:ok, context}
      end

      then_ "the message carries every agent and what it is doing", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        missing = Enum.reject(context.agents, &(html =~ &1.id))

        assert missing == [],
               """
               #{length(missing)} of the three agents are not in the digest.

               "What is going on" includes the ones that are fine — that is what
               makes the one that is not stand out. A digest that reported only
               the interesting agent would leave the main agent unable to tell a
               quiet fleet from a partial report.

               transcript:
               #{html}
               """

        {:ok, context}
      end

      then_ "and the main agent did not have to go and assemble it", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        assert html =~ ~r/last said|nothing to do|task:/i,
               """
               The wake-up says it is time to check in and nothing else.

               That costs a turn before anything is known — `list_agent_work`,
               then `check_machinery`, then thinking — seventy-two times a day
               on the machine that is also running the agents.

               And a wake-up that says nothing is one an agent can reasonably
               dismiss: told "look at your agents" with no reason to think
               anything is wrong, the cheapest correct-looking response is a
               glance, and the check-in becomes ceremony.

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end

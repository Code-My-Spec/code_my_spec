defmodule CodeMySpecSpex.Story1059.Criterion3319Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3319 — An agent that went silent is caught by the check-in.

  Rule: the check-in finds what nothing could have reported.

  The criterion the whole story exists for. Every other way the main agent
  learns anything requires the agent in trouble to still be working well enough
  to say so — and the failure worth catching is precisely the one where it is
  not.

  The observed case: one outage was visible only because the affected agent
  could still call `send_message`. Had it lost that too, it would have sat
  silent indefinitely, and the project would have looked exactly as it looks
  when everything is fine.

  ## What "cannot report" means in the scenario

  The agent holds a task, spoke once hours ago, and has said nothing since. No
  question, no tap-out, no turn — nothing that would reach anybody. It is
  indistinguishable from a healthy agent right up to the moment somebody looks
  at how long it has been.
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

  spex "The check-in notices what nobody was told" do
    scenario "an agent has held a task in silence for hours" do
      given_ "a main agent and an agent that has gone quiet", context do
        reply = join_working_copy(context, "/tmp/spex-3319", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3319")
        quiet = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3319")

        {_agent, _task} =
          Fixtures.agent_task_fixture(scope, quiet,
            requirement_name: "implementation_file",
            started_at: DateTime.add(DateTime.utc_now(), -3 * 60 * 60, :second)
          )

        # It spoke once and has said nothing since. No question, no tap-out, no
        # turn — nothing that would reach anybody.
        :ok = Fixtures.agent_said(scope, quiet, "starting on the exporter")
        :ok = Fixtures.age_agent_messages(scope, quiet, 3 * 60 * 60)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:quiet, quiet)}
      end

      when_ "the cadence comes round", context do
        :ok = Fixtures.cadence_tick(context.scope)

        {:ok, context}
      end

      then_ "the main agent can see it has gone quiet", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        assert html =~ context.quiet.id,
               """
               The silent agent is not in the check-in at all.

               This is the criterion the story exists for: every other way the
               main agent learns anything needs the agent in trouble to still be
               working well enough to say so, and the failure worth catching is
               the one where it is not.

               transcript:
               #{html}
               """

        assert html =~ ~r/last said|silent|no message/i,
               """
               The agent is listed and nothing says how long it has been quiet.

               It is indistinguishable from a healthy one right up to the moment
               somebody looks at the time, and looking at the time is the whole
               of what this check-in had to do.

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end

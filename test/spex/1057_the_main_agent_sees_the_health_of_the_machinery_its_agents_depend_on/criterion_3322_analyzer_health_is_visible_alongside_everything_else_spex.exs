defmodule CodeMySpecSpex.Story1057.Criterion3322Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3322 — Analyzer health is visible alongside everything else.

  Rule: the thing that judges the work is part of the machinery.

  The analyzers are the least obviously "machinery" of the lot and the most
  costly when they are wrong, because they are what every gate reads. An agent
  whose analyzers are not running is refused at every stop for want of a fresh
  result — and the refusal it reads says nothing about analyzers, only that the
  gate is not satisfied.

  So the criterion's second half is the sharp one: a gate failing for want of a
  working analyzer has to be distinguishable from a gate failing on its merits.
  Those are opposite situations. One means fix your code; the other means the
  thing that would tell you whether your code is fixed is not running, and
  nothing you do to the code will change the answer.

  The observed shape of getting that wrong is an agent editing the same file
  over and over against a verdict that never moves, which reads from outside as
  an agent that cannot do its job.

  ## Why this is not story 1054's problem list

  `list_agent_work` reports the problems on a copy — the analyzers' *output*.
  This reports whether the analyzers ran at all, which output cannot answer: a
  suite that never ran and a suite that found nothing both produce no problems,
  and they mean opposite things.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Whether the analyzers are working is part of the report" do
    scenario "one analyzer has failed and the rest are fine" do
      given_ "a checkout whose exunit analyzer failed and whose others ran",
             context do
        reply = join_working_copy(context, "/tmp/spex-3322", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        _agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3322")

        Fixtures.fresh_analysis_runs(scope, ["compiler", "credo", "spex"])
        _failed = Fixtures.failed_analysis_run(scope, "exunit")

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the analyzers are reported", context do
        assert context.report =~ ~r/analyz/i,
               """
               The analyzers are not in the machinery report.

               They are the least obviously "machinery" of the lot and the most
               costly when they are wrong, because every gate reads them. An
               agent whose analyzers are not running is refused at every stop
               for want of a fresh result, and the refusal it reads says nothing
               about analyzers.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "and the one that failed is named apart from the ones that ran",
            context do
        assert context.report =~ "exunit",
               """
               The failed analyzer is not named.

               "The analyzers are unhealthy" does not tell the main agent which
               gate to distrust, and the gates are not interchangeable: a broken
               exunit makes `tests_passing` unanswerable and leaves every other
               requirement exactly as trustworthy as before.

               report:
               #{context.report}
               """

        refute context.report =~ ~r/credo[^\\n]*(failed|broken|not running)/i,
               """
               An analyzer that ran is being reported as failed alongside the one
               that did.

               If every analyzer is suspect then no gate can be believed, which
               is indistinguishable from having no gates — and the remedy for
               that is nothing anybody can act on.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story1057.Criterion3323Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3323 — An analyzer that is not really running is not reported as
  passing.

  Rule: a verdict is only as current as the run behind it.

  The worst failure available anywhere in this story fails *safe*: everything
  goes green, and work promotes on the strength of a suite that has not seen
  the code it is judging.

  ## Since 28d72f8a

  There is no "stale" state to report. Fingerprint freshness is gone; the
  promote gate asks for a completed run at HEAD on a clean tree, so an old run
  can no longer promote anything. What the report owes the main agent is the
  facts it can check — which run, at which commit, how long ago — and never a
  word that reads as "passing". This criterion's wording should be retired or
  reworded to "an analyzer's report names its run, never a verdict".
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

  spex "An old run is reported as a run, not as a passing verdict", criterion: 1291 do
    scenario "an analyzer completed some time ago" do
      given_ "a checkout whose exunit run completed earlier",
             context do
        reply = join_working_copy(context, "/tmp/spex-3323", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        _agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3323")

        # A completed run, no problems, no commit recorded.
        _run = Fixtures.completed_analysis_run(scope, "exunit")

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the main agent looks at analyzer health", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "it is reported with when its run completed", context do
        assert context.report =~ ~r/exunit[^\n]*last run completed[^\n]*ago/,
               """
               The report has to say which run the analyzer's state comes from,
               so the main agent can judge its age itself.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "and its result is not offered as a verdict", context do
        refute context.report =~ ~r/exunit[^\\n]*(passing|clean|no problems)/i,
               """
               The run's result is being reported as a verdict on the code here
               now, which nothing but the promote gate can say.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end

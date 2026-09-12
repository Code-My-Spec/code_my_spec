defmodule CodeMySpecSpex.Story1057.Criterion3323Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3323 — An analyzer that is not really running is not reported as
  passing.

  Rule: a verdict is only as fresh as the run behind it.

  The worst failure available anywhere in this story, because it fails *safe*:
  everything goes green. An analyzer whose result is stale reports no problems,
  every gate it feeds opens, and work promotes on the strength of a suite that
  has not seen the code it is judging.

  Nothing complains. That is the whole difficulty — a broken analyzer that
  errors is a nuisance somebody fixes within the hour, and one that quietly
  answers from last week's run is trusted indefinitely.

  ## Stale and absent are the same claim here

  The criterion says "returns a result without having run", and the shape that
  takes in this system is a completed run whose input fingerprint no longer
  matches the files — the run happened, against something else. The verdict
  exists, is well-formed, and describes code that is gone.

  ## Both halves

  Visible as a fault, *and* its results not treated as fresh. A report that
  flagged the staleness while the gates went on believing the numbers would be a
  warning nobody reads, beside an outcome nobody questions.
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

  spex "A stale verdict is not a passing one" do
    scenario "an analyzer completed against code that is no longer there" do
      given_ "a checkout whose exunit run completed against different files",
             context do
        reply = join_working_copy(context, "/tmp/spex-3323", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        _agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3323")

        # A completed run, no problems, and a fingerprint that no longer matches
        # what is on disk. Well-formed, green, and about code that is gone.
        _stale = Fixtures.stale_analysis_run(scope, "exunit")

        {:ok, Map.put(context, :scope, scope)}
      end

      when_ "the main agent looks at analyzer health", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "it is visible as a fault", context do
        assert context.report =~ ~r/stale|out of date|has not run|not been run/i,
               """
               An analyzer answering from a run against code that is gone is
               reported as if it had run.

               This is the worst failure in the story because it fails safe:
               everything goes green, every gate it feeds opens, and work
               promotes on the strength of a suite that never saw the code it is
               judging. Nothing complains — which is why a broken analyzer that
               errors gets fixed within the hour and one that quietly answers
               from last week is trusted indefinitely.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "and its result is not offered as a fresh verdict", context do
        refute context.report =~ ~r/exunit[^\\n]*(passing|clean|no problems)/i,
               """
               The stale run's result is being reported as a verdict.

               Flagging the staleness while still quoting the numbers is a
               warning nobody reads beside an outcome nobody questions. The
               result is not a weaker answer than a fresh one — it is an answer
               to a different question.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end

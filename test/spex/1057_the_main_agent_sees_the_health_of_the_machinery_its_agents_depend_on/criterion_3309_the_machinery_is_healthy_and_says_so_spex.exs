defmodule CodeMySpecSpex.Story1057.Criterion3309Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3309 — The machinery is healthy and says so.

  The first spex on this story, so it chooses the surface the rest inherit:
  `CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery`, beside
  `list_agent_work` on the same server.

  ## Why not another section of `list_agent_work`

  They answer opposite questions and the whole story is about telling them
  apart. `list_agent_work` reports per agent; this reports the things *under*
  every agent, which is what makes "all of them at once" (3310) legible as one
  fault rather than as several. Folded into the per-agent view, shared machinery
  would be repeated against each agent — which is exactly the reading the story
  exists to prevent.

  ## Healthy is the case worth asserting first

  A tool that can only report faults is not much use to the main agent: the
  question it actually asks is "is it me or is it the machine", and half the
  answers to that are "the machine is fine". Silence answers it wrongly —
  nothing shown is indistinguishable from nothing checked, and the main agent
  guesses in the direction that costs, which is restarting agents.

  So the assertion is that each piece is named and shown working, and the
  criterion's second half — "the main agent can rule it out" — is exactly that:
  ruling something out needs a positive statement, not an absence.
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

  spex "Working machinery says it is working" do
    scenario "the harness, the tools and the preview are all up" do
      given_ "a connected checkout with tools and a serving preview", context do
        reply =
          join_working_copy(context, "/tmp/spex-3309", "the checkout",
            preview_url: "https://preview-3309.example.com"
          )

        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The three things an agent depends on, each reported the way the
        # machine reports it.
        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        Fixtures.record_preview_status(reply.working_copy_id, :serving)
        Fixtures.fresh_analysis_runs(scope)

        _agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3309")

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:copy_id, reply.working_copy_id)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "each piece is named and shown working", context do
        assert context.report =~ ~r/harness/i,
               "the harness is not in the report:\n#{context.report}"

        assert context.report =~ ~r/tools/i,
               "the tool surface is not in the report:\n#{context.report}"

        assert context.report =~ ~r/preview/i,
               "the preview is not in the report:\n#{context.report}"

        {:ok, context}
      end

      then_ "and each says it is working rather than saying nothing", context do
        refute context.report =~ ~r/unknown|not checked|no data/i,
               """
               A piece of the machinery is reported as unknown while it is
               plainly working.

               Nothing shown is indistinguishable from nothing checked, and the
               main agent then guesses in the direction that costs — restarting
               agents to clear a fault that is not there.

               report:
               #{context.report}
               """

        assert context.report =~ ~r/working|healthy|connected|serving|ok\b/i,
               """
               Nothing in the report says the machinery is working.

               "The main agent can rule it out" is the criterion, and ruling
               something out needs a positive statement. A tool that can only
               report faults leaves the question it exists to answer — is it me
               or is it the machine — unanswered exactly half the time.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end

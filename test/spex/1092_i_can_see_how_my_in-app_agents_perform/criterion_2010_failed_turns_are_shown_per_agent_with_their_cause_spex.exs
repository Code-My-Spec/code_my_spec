defmodule CodeMySpecSpex.Story1092.Criterion2010Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2010 -- Failed turns are shown per agent with their cause.

  Rule: Failed turns and tool-call failures are shown per agent, with
  their cause.

  Driven through the same `agent_turn_event` push `CmsHarness.Agents.Engine`
  sends on a `turn_failed` kind -- see `Fixtures.end_turn/3`'s own doc for
  why a spec drives the channel's entry rather than a second version of it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A turn that failed on a timeout is shown against its agent, with that cause",
       criterion: 2010 do
    scenario "an agent's turn failed during a period" do
      given_ "a running agent", context do
        reply = join_working_copy(context, "/tmp/spex-2010", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2010")
        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "its turn fails on a timeout", context do
        :ok =
          Fixtures.fail_turn(
            context.scope,
            context.agent.id,
            "the model took longer than its deadline and the turn was cut off"
          )

        {:ok, context}
      end

      then_ "I see how many turns failed, and each failure's cause", context do
        {:ok, _show, html} = live(context.conn, show_path(context, context.agent))

        assert html =~ "1", "the agent's one failed turn is not counted"

        assert html =~ "timeout" or html =~ "timed out" or html =~ "took longer",
               "the failed turn's cause (a timeout) is not named"

        {:ok, context}
      end
    end
  end
end

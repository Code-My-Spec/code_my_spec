defmodule CodeMySpecSpex.Story1092.Criterion2014Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2014 -- Offers superseded by a restart are not counted as
  ignored.

  Rule: Offer health is shown per role: claim rate, time to claim,
  ignored and declined offers -- and an offer a restart overtook before
  the agent could act on it is neither.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.MessageAgent
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    Fixtures.use_recording_transport(context)
  end

  spex "A queued offer a restart overtakes before delivery is superseded, not ignored",
    criterion: 2014 do
    scenario "a resume offer was superseded when the harness restarted" do
      given_ "a busy agent with a message queued for its next turn", context do
        reply = join_working_copy(context, "/tmp/spex-2014", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        {:ok, _integration} = Fixtures.connect_provider(scope, :zai)
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2014")

        Fixtures.put_agent_mid_turn(scope, agent.id)

        frame = %Frame{assigns: %{current_scope: scope}}

        {:reply, sent, _frame} =
          MessageAgent.execute(%{agent_id: agent.id, message: "next thing to look at"}, frame)

        refute sent.isError, inspect(sent)
        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the agent is restarted before that offer is delivered", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, restarted, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent.id, reason: "stuck mid-turn"},
            frame
          )

        refute restarted.isError, inspect(restarted)
        {:ok, context}
      end

      then_ "offer health shows it as superseded", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)

        assert html =~ "superseded",
               "the offer the restart overtook before delivery is not shown as superseded"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and it does not lower the coding role's claim rate", context do
        refute context.html =~ "ignored" and context.html =~ "coding",
               "the superseded offer is counted as ignored against the coding role, lowering its claim rate"

        {:ok, context}
      end
    end
  end
end

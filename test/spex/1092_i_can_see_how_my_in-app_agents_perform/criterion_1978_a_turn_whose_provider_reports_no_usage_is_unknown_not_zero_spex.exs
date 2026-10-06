defmodule CodeMySpecSpex.Story1092.Criterion1978Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1978 -- A turn whose provider reports no usage is unknown, not zero.
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

  spex "A turn with no usage in the provider's response is unknown, not free", criterion: 1978 do
    scenario "a turn ends without the provider reporting usage" do
      given_ "a running agent", context do
        reply = join_working_copy(context, "/tmp/spex-1978", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1978")
        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the turn ends with no usage on the response", context do
        :ok =
          Fixtures.record_turn(
            context.scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}]
            },
            session_id: "spex-1978",
            agent_role: "coding"
          )

        {:ok, context}
      end

      then_ "its tokens are shown as unknown, not as a free turn", context do
        {:ok, _show, html} = live(context.conn, show_path(context, context.agent))

        assert html =~ "unknown",
               "a turn with no reported usage is not shown as unknown"

        refute html =~ "0 tokens",
               "a turn with no reported usage is shown as costing nothing, which is not the same as unknown"

        {:ok, context}
      end
    end
  end
end

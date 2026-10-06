defmodule CodeMySpecSpex.Story1092.Criterion2053Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2053 -- John narrows the chart to one agent.
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

  spex "John narrows the chart to one agent", criterion: 2053 do
    scenario "a project whose team holds two agents, each with their own recorded turn" do
      given_ "John is looking at the agent performance view for a project whose teams hold several agents",
             context do
        copy = join_working_copy(context, "/tmp/spex-2053", "the team")
        scope = %{context.scope | active_working_copy_id: copy.working_copy_id}

        agent_a =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2053")

        :ok =
          Fixtures.record_turn(
            scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 200}
            },
            session_id: "spex-2053-a",
            agent_role: "coding"
          )

        Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2053")

        :ok =
          Fixtures.record_turn(
            scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 150, "output_tokens" => 250}
            },
            session_id: "spex-2053-b",
            agent_role: "qa"
          )

        {:ok, index, _html} = live(context.conn, index_path(context))

        context =
          context
          |> Map.put(:index, index)
          |> Map.put(:agent_id, agent_a.id)

        {:ok, context}
      end

      when_ "he picks one agent from the controls on the page", context do
        html =
          context.index
          |> element("form[data-test='performance-filter']")
          |> render_change(%{"agent_id" => context.agent_id})

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart and its detail show that agent's turns, failures and token use only", context do
        assert context.html =~ "300 tokens",
               "the picked agent's own token total (300) is not shown once the chart is narrowed to it"

        {:ok, context}
      end

      then_ "the totals for the other agents are excluded rather than greyed out", context do
        refute context.html =~ "700 tokens",
               "the unfiltered combined total (700) is still shown once the chart is narrowed to one agent"

        {:ok, context}
      end
    end
  end
end

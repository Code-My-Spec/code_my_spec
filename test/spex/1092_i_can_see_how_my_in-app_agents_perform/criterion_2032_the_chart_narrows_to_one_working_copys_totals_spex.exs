defmodule CodeMySpecSpex.Story1092.Criterion2032Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2032 -- The chart narrows to one working copy's totals.
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

  spex "Narrowing the chart to one working copy shows only that working copy's totals",
    criterion: 2032 do
    scenario "two working copies each recorded their own turn" do
      given_ "two working copies, each with their own recorded turn", context do
        copy_a = join_working_copy(context, "/tmp/spex-2032-a", "team A")
        scope_a = %{context.scope | active_working_copy_id: copy_a.working_copy_id}
        Fixtures.running_agent(scope_a, role: "coding", working_copy: "/tmp/spex-2032-a")

        :ok =
          Fixtures.record_turn(
            scope_a,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 200}
            },
            session_id: "spex-2032-a",
            agent_role: "coding"
          )

        copy_b = join_working_copy(context, "/tmp/spex-2032-b", "team B")
        scope_b = %{context.scope | active_working_copy_id: copy_b.working_copy_id}
        Fixtures.running_agent(scope_b, role: "coding", working_copy: "/tmp/spex-2032-b")

        :ok =
          Fixtures.record_turn(
            scope_b,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 150, "output_tokens" => 250}
            },
            session_id: "spex-2032-b",
            agent_role: "coding"
          )

        {:ok, Map.put(context, :working_copy_id, copy_a.working_copy_id)}
      end

      when_ "I narrow the chart to team A's working copy", context do
        {:ok, index, _html} = live(context.conn, index_path(context))

        index
        |> element("form[data-test='performance-filter']")
        |> render_change(%{"working_copy_id" => context.working_copy_id, "story_id" => ""})

        html = await_report(index)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart's totals are team A's alone", context do
        assert context.html =~ "300 tokens",
               "team A's own token total (300) is not shown once the chart is narrowed to its working copy"

        refute context.html =~ "700 tokens",
               "the unfiltered combined total (700) is still shown once the chart is narrowed to one working copy"

        {:ok, context}
      end
    end
  end
end

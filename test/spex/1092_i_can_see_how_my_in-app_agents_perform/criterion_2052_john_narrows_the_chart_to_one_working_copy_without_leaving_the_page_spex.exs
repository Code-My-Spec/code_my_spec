defmodule CodeMySpecSpex.Story1092.Criterion2052Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2052 -- John narrows the chart to one working copy without
  leaving the page.
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

  spex "John narrows the chart to one working copy without leaving the page",
    criterion: 2052 do
    scenario "a project with two working copies, each with their own recorded turn" do
      given_ "John is looking at the agent performance view for a project with two working copies",
             context do
        copy_a = join_working_copy(context, "/tmp/spex-2052-a", "team A")
        scope_a = %{context.scope | active_working_copy_id: copy_a.working_copy_id}
        Fixtures.running_agent(scope_a, role: "coding", working_copy: "/tmp/spex-2052-a")

        :ok =
          Fixtures.record_turn(
            scope_a,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 200}
            },
            session_id: "spex-2052-a",
            agent_role: "coding"
          )

        copy_b = join_working_copy(context, "/tmp/spex-2052-b", "team B")
        scope_b = %{context.scope | active_working_copy_id: copy_b.working_copy_id}
        Fixtures.running_agent(scope_b, role: "coding", working_copy: "/tmp/spex-2052-b")

        :ok =
          Fixtures.record_turn(
            scope_b,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 150, "output_tokens" => 250}
            },
            session_id: "spex-2052-b",
            agent_role: "coding"
          )

        {:ok, index, _html} = live(context.conn, index_path(context))

        context =
          context
          |> Map.put(:index, index)
          |> Map.put(:index_pid, index.pid)
          |> Map.put(:working_copy_id, copy_a.working_copy_id)

        {:ok, context}
      end

      when_ "he picks one of them from the controls on the page", context do
        context.index
        |> element("form[data-test='performance-filter']")
        |> render_change(%{"working_copy_id" => context.working_copy_id, "story_id" => ""})

        html = await_report(context.index)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart and its detail show that working copy's totals only", context do
        assert context.html =~ "300 tokens",
               "team A's own token total (300) is not shown once the chart is narrowed to its working copy"

        refute context.html =~ "700 tokens",
               "the unfiltered combined total (700) is still shown once the chart is narrowed to one working copy"

        {:ok, context}
      end

      then_ "he did not have to edit the address bar to do it", context do
        assert context.index.pid == context.index_pid,
               "narrowing the chart required leaving or reloading the page"

        {:ok, context}
      end
    end
  end
end

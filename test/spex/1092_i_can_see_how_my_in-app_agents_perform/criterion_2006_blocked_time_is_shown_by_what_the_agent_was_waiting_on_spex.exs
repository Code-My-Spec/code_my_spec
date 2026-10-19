defmodule CodeMySpecSpex.Story1092.Criterion2006Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2006 -- Blocked time is shown by what the agent was waiting on.

  Rule: Time agents spend blocked is shown by cause: questions, tap-outs,
  issues.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Agents blocked on questions and tap-outs show the time and who they are waiting on",
    criterion: 2006 do
    scenario "agents waited on a question and a tap-out during a period" do
      given_ "one agent blocked on a tap-out and another blocked on a question to the user",
             context do
        reply = join_working_copy(context, "/tmp/spex-2006", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        tapped_agent =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2006")

        asking_1 = %Frame{assigns: %{current_scope: scope, agent_id: tapped_agent.id}}

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "this task's premise does not hold"},
            Map.put(asking_1.assigns, :scope, asking_1.assigns[:current_scope])
          )

        assert match?({:ok, _}, tapped), inspect(tapped)

        asking_agent =
          Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-2006")

        asking_2 = %Frame{assigns: %{current_scope: scope, agent_id: asking_agent.id}}

        asked =
          ToolLibrary.run(
            "ask_question",
            %{questions: [%{question: "Which environment should this target?", options: []}]},
            Map.put(asking_2.assigns, :scope, asking_2.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:tapped_agent, tapped_agent)
         |> Map.put(:asking_agent, asking_agent)}
      end

      when_ "I look at blocked time", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "I see the time spent waiting on each cause", context do
        assert context.html =~ "question", "blocked time on a question is not shown"

        assert context.html =~ "tap-out" or context.html =~ "tap out",
               "blocked time on a tap-out is not shown"

        {:ok, context}
      end

      then_ "and who it was waiting on: the main agent, the user or another team", context do
        assert context.html =~ "user",
               "neither blocked cause names the user as who the agent is waiting on"

        {:ok, context}
      end
    end
  end
end

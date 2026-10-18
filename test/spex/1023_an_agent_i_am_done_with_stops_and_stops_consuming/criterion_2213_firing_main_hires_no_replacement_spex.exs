defmodule CodeMySpecSpex.Story1023.Criterion2213Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2213 — Firing main hires no replacement.

  Rule: firing an agent hires no replacement; main's seat stays empty until
  a person starts one directly, not as a side effect of staffing its copy.

  John, on 2212: "Drop it. Straight get rid of the agent." And then, on main
  specifically: "No rehire for main either." Every other role's retired seat
  is still one `ensure_copy_agents` fills on request — this is main's alone.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Firing main hires no replacement", criterion: 2213 do
    scenario "Firing main hires no replacement" do
      given_ "a running main agent, fired", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        start_agent(main.id, working_copy: main.working_copy)

        assert running?(main.id),
               "the premise is a live main agent; without one, firing it and finding " <>
                 "no replacement proves nothing"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run(
            "retire_agent",
            %{"agent_id" => main.id},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        assert match?({:ok, _}, reply), "firing the main agent itself failed"

        {:ok, Map.put(context, :main, main)}
      end

      when_ "its copy is staffed again", context do
        {:ok, view, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.main.working_copy_id}"
          )

        assert has_element?(view, "[data-test='staff-copy']"),
               "the copy is not offered staffing at all, so pressing it proves nothing " <>
                 "about main specifically staying unfilled"

        view
        |> element("[data-test='staff-copy']")
        |> render_click()

        {:ok, context}
      end

      then_ "no new main agent is running", context do
        refute context.scope
               |> Agents.list_on_duty()
               |> Enum.any?(&(&1.role == :main)),
               "pressing Staff it hired a replacement for a fired main — its seat should " <>
                 "stay empty until a person starts one directly"

        {:ok, context}
      end

      then_ "and the fired main stays retired", context do
        refute running?(context.main.id),
               "the fired main agent is somehow running again"

        {:ok, context}
      end
    end
  end
end

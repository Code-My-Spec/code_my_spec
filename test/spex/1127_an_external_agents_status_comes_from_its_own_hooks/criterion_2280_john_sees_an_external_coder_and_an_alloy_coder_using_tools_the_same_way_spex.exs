defmodule CodeMySpecSpex.Story1127.Criterion2280Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2280 — John sees an external coder and an Alloy coder using tools the same way.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp open_activity_panel(_view, html, true), do: html

  defp open_activity_panel(view, _html, false),
    do: render_hook(view, "toggle_panel", %{"panel" => "activity"})

  # The cockpit's team panel: the page John watches his agents on.
  defp cockpit(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

    # The team panel is a drawer; John opens it to see his agents.
    render_hook(view, "viewport", %{"width" => 1200})
    html = render(view)

    html =
      open_activity_panel(
        view,
        html,
        html =~ ~r/data-test="panel-activity"[^>]*data-panel-open="true"/
      )

    {view, html}
  end

  # A terminal agent in `role`, whose session is open and whose hooks fire. Its
  # state comes from those hooks alone, so Claude Code's own agent list is left
  # idle throughout.
  defp a_terminal_agent(context, role) do
    context = HarnessHooks.ensure_live_harness(context)
    inbox = open_inbox()
    session = session_id()
    started = start_session_on_socket(context, session, inbox.socket)
    assert {:ok, _} = set_role(context, session, role)
    look(started["agent_id"])

    Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})
  end

  defp hook(context, name, extra),
    do:
      HarnessHooks.post_hook(context, name, Map.merge(%{"session_id" => context.session}, extra))

  # Which agent's row lacks what, for a failure to name: 2280 fails only in
  # full sweeps, with one of the two rows missing its tool activity.
  defp rows(html, context) do
    names = %{context.agent_id => :terminal, context.alloy_id => :alloy}

    html
    |> Floki.parse_document!()
    |> Floki.find(~s([data-test="team-agent"]))
    |> Enum.map(fn row ->
      [id] = Floki.attribute(row, "data-agent-id")

      {Map.get(names, id, id),
       turn: Floki.find(row, ~s([data-test="team-agent-turn"])) != [],
       tool: Floki.attribute(row, ~s([data-test="team-agent-tool"]), "data-count")}
    end)
  end

  spex "An external coder and an Alloy coder show their tool activity alike", criterion: 2280 do
    scenario "both are mid-turn running a test" do
      given_ "an external coder and an Alloy coder are each mid-turn running a test", context do
        context = a_terminal_agent(context, "coding")

        hook(context, "user-prompt-submit", %{"prompt" => "Run the tests."})

        hook(context, "pre-tool-use", %{
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
        })

        alloy = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "coding")
        :ok = CodeMySpecSpex.Fixtures.put_agent_mid_turn(context.scope, alloy.id)

        :ok =
          CodeMySpecSpex.Fixtures.start_turn(context.scope, alloy.id,
            event: :tool_start,
            payload: %{id: "tool-1", name: "Bash", input: %{"command" => "mix test"}}
          )

        {:ok, Map.put(context, :alloy_id, alloy.id)}
      end

      when_ "John opens the team panel", context do
        {view, _html} = cockpit(context)
        {:ok, Map.put(context, :view, view)}
      end

      then_ "both show their current tool activity in the same form", context do
        eventually(fn ->
          {_view, html} = cockpit(context)

          activity =
            Regex.scan(
              ~r/data-test="team-agent-tool"[^>]*data-tool="([^"]*)"[^>]*data-count="([^"]*)"/,
              html
            )
            |> Enum.map(fn [_, tool, count] -> {tool, count} end)

          assert [first, second] = activity,
                 "each agent's row shows its tool activity; got #{inspect(activity)} " <>
                   "from rows #{inspect(rows(html, context))}"

          assert first == second,
                 "the two rows must show it in the same form; got #{inspect(activity)}"

          assert first == {"Bash", "1"}
          refute html =~ "mix test", "the row shows a tool icon and tally, never the command"
        end)

        {:ok, context}
      end
    end
  end
end

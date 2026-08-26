defmodule CodeMySpecSpex.Story966.Criterion2951Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2951 — Opening one tab on a phone closes the others.

  A phone has one slot. Two open panels there means the conversation is pushed
  off the bottom of the screen, which costs the founder the half they came for.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The screen rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "On a narrow screen at most one panel is open at a time" do
    scenario "Opening one tab on a phone closes the others" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "I am on a phone", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 390})
        {:ok, Map.put(context, :live, live)}
      end

      given_ "the preview open", context do
        context.live
        |> element(~s([data-test="panel-tab-preview"]))
        |> render_click()

        {:ok, context}
      end

      when_ "I open the activity tab", context do
        html =
          context.live
          |> element(~s([data-test="panel-tab-activity"]))
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the preview closes", context do
        assert context.html =~ ~s(data-test="panel-preview" data-panel-open="false"),
               "the preview stayed open, so a phone is showing two panels and the " <>
                 "conversation is off the bottom of the screen"

        {:ok, context}
      end

      then_ "and only the activity tab is open", context do
        open = Regex.scan(~r/data-panel-open="true"/, context.html) |> length()

        assert open == 1,
               "#{open} panels are open on a narrow screen, where there is room for one"

        {:ok, context}
      end
    end
  end
end

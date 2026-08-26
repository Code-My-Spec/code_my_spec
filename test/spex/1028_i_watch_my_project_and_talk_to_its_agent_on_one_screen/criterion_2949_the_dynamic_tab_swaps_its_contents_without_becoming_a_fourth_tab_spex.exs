defmodule CodeMySpecSpex.Story966.Criterion2949Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2949 — The dynamic tab swaps its contents without becoming a fourth tab.

  The dynamic tab is one tab that shows different things, not a family of tabs.
  If swapping its contents grows the accordion, the design has quietly become a
  navigation menu and the mobile single-slot rule stops meaning anything.
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

  spex "The accordion has three tabs: the preview, a dynamic tab whose content changes, and activity from the rest of the project" do
    scenario "The dynamic tab swaps its contents without becoming a fourth tab" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "the dynamic tab showing the stories menu", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))

        live
        |> element(~s([data-test="panel-tab-dynamic"]))
        |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "the view changes to a single story", context do
        html = render_hook(context.live, "dynamic_view", %{"view" => "story"})
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the dynamic tab shows that story", context do
        assert context.html =~ ~s(data-dynamic-view="story"),
               "the dynamic tab did not change what it is showing"

        {:ok, context}
      end

      then_ "and the accordion still has the same three tabs", context do
        tabs = Regex.scan(~r/data-test="panel-tab-/, context.html) |> length()

        assert tabs == 3,
               "the accordion has #{tabs} tabs. Swapping the dynamic tab's contents " <>
                 "grew the accordion, which makes it a navigation menu rather than " <>
                 "three panels."

        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story966.Criterion2952Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2952 — A stored desktop layout with several tabs open resolves to the preview on a phone.

  The stored layout is a desk layout, and a phone cannot honour it. Something has
  to give, and it has to be decided rather than arbitrary — otherwise which panel
  survives depends on render order, which nobody can predict or explain.
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
    scenario "A stored desktop layout with several tabs open resolves to the preview on a phone" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "a layout I left with the preview and the dynamic tab both open", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 1440})

        live |> element(~s([data-test="panel-tab-preview"])) |> render_click()
        live |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "I open the same project on my phone", context do
        html = render_hook(context.live, "viewport", %{"width" => 390})
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the preview is the one shown", context do
        assert context.html =~ ~s(data-test="panel-preview" data-panel-open="true"),
               "the preview is not the panel that survived the move to a phone"

        {:ok, context}
      end

      then_ "and the other tabs are closed", context do
        open = Regex.scan(~r/data-panel-open="true"/, context.html) |> length()

        assert open == 1,
               "#{open} panels are open on a phone. A stored desk layout has to resolve " <>
                 "to one, and to a decided one rather than whichever renders first."

        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story966.Criterion2948Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2948 — A panel with no preview yet explains itself.

  An empty panel and a broken panel look identical, and the difference matters
  most to the person least able to tell — which is exactly who this screen is
  for. Saying what would start one is the half that turns a dead end into a next
  step.
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

  spex "A panel with nothing to show says why, rather than appearing broken or empty" do
    scenario "A panel with no preview yet explains itself" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "a project with no preview running", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :live, live)}
      end

      when_ "I open the preview panel", context do
        html =
          context.live
          |> element(~s([data-test="panel-tab-preview"]))
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it tells me no preview is running", context do
        assert context.html =~ ~s(data-test="panel-preview-empty"),
               "the preview panel renders nothing to explain itself, so an unstarted " <>
                 "preview is indistinguishable from a broken one"

        {:ok, context}
      end

      then_ "and it says what would start one", context do
        assert context.html =~ ~s(data-test="panel-preview-remedy"),
               "the panel says the preview is not running but not what to do about " <>
                 "it, which leaves the reader exactly where they were"

        {:ok, context}
      end
    end
  end
end

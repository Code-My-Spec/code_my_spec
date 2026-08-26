defmodule CodeMySpecSpex.Story966.Criterion2947Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2947 — Opening a panel does not cost Sam his place.

  A half-typed reply is the expensive thing on this screen. Scroll position is
  client state a server-rendered test cannot see; the draft is not, and it is the
  half that actually costs something to lose.
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

  spex "Opening or closing a panel leaves the conversation where Sam left it" do
    scenario "Opening a panel does not cost Sam his place" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "a reply I have typed but not sent", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))

        live
        |> form(~s([data-test="conversation-composer"]), %{"message" => "half a thought"})
        |> render_change()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "I open a panel", context do
        html =
          context.live
          |> element(~s([data-test="panel-tab-preview"]))
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the reply I typed is still in the box", context do
        assert context.html =~ "half a thought",
               "opening a panel threw away the message being written, which is the " <>
                 "most expensive thing on this screen to lose"

        {:ok, context}
      end
    end
  end
end

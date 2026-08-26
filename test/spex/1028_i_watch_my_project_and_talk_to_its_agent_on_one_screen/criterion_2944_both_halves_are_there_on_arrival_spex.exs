defmodule CodeMySpecSpex.Story966.Criterion2944Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2944 — Both halves are there on arrival.

  The point of the screen is watching and asking at the same time. If either half
  costs a navigation, the founder is back to alternating between two pages, which
  is the thing this replaces.
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

  spex "The conversation and the project's panels are on screen together, with no navigation between them" do
    scenario "Both halves are there on arrival" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      when_ "I open my project's agent conversation", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the conversation is on the screen", context do
        assert context.html =~ ~s(data-test="agent-conversation"),
               "the conversation is not on the screen"

        {:ok, context}
      end

      then_ "and the panels are on the same screen", context do
        assert context.html =~ ~s(data-test="conversation-panels"),
               "the panel accordion is not on the screen, so watching and asking are " <>
                 "still two separate places"

        {:ok, context}
      end
    end
  end
end

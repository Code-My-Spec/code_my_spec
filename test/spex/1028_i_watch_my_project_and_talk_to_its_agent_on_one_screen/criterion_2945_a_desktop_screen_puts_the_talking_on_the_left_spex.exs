defmodule CodeMySpecSpex.Story966.Criterion2945Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2945 — A desktop screen puts the talking on the left.

  "Left" is a rendering claim and a server-rendered page has no pixels. What it
  does have is the order the two halves are written in and the layout the page
  declares it is using, which together are what produce left and right. Asserted
  that way rather than by naming a CSS class, so the spec survives a restyle.
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

  spex "On a wide screen the conversation sits beside the panels, with the conversation on the left" do
    scenario "A desktop screen puts the talking on the left" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "I am at my desk on a wide screen", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 1440})
        {:ok, Map.put(context, :live, live)}
      end

      when_ "I look at the screen", context do
        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the screen lays itself out side by side", context do
        assert context.html =~ ~s(data-layout="wide"),
               "the page does not report a wide layout, so nothing distinguishes a " <>
                 "desk from a phone"

        {:ok, context}
      end

      then_ "and the conversation comes before the panels", context do
        {chat_at, _} = :binary.match(context.html, ~s(data-test="agent-conversation"))
        {panels_at, _} = :binary.match(context.html, ~s(data-test="conversation-panels"))

        assert chat_at < panels_at,
               "the panels are rendered before the conversation, so the talking is on " <>
                 "the right"

        {:ok, context}
      end
    end
  end
end

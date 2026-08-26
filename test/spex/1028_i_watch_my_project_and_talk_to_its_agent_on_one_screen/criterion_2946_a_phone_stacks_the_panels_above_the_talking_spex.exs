defmodule CodeMySpecSpex.Story966.Criterion2946Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2946 — A phone stacks the panels above the talking.

  The mirror of 2945, and the same reasoning: order plus the declared layout is
  what produces above and below.
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

  spex "On a narrow screen the panels sit above the conversation" do
    scenario "A phone stacks the panels above the talking" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "I am on a phone", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 390})
        {:ok, Map.put(context, :live, live)}
      end

      when_ "I look at the screen", context do
        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the screen lays itself out stacked", context do
        assert context.html =~ ~s(data-layout="narrow"),
               "the page does not report a narrow layout, so it cannot be stacking " <>
                 "anything for a phone"

        {:ok, context}
      end

      then_ "and the panels come before the conversation", context do
        {chat_at, _} = :binary.match(context.html, ~s(data-test="agent-conversation"))
        {panels_at, _} = :binary.match(context.html, ~s(data-test="conversation-panels"))

        assert panels_at < chat_at,
               "the conversation is rendered before the panels, so on a phone the " <>
                 "panels sit below the chat rather than above it"

        {:ok, context}
      end
    end
  end
end

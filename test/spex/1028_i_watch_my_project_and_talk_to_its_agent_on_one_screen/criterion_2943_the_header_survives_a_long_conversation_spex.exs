defmodule CodeMySpecSpex.Story966.Criterion2943Spex do
  @moduledoc """
  Story 966 — I watch my project and talk to its agent on one screen.
  Criterion 2943 — The header survives a long conversation.

  The header describes the whole project, so it cannot live inside the part of
  the screen that scrolls away. Encoded as containment rather than as pixels: a
  server-rendered page cannot be scrolled, but it can say whether the header sits
  inside the scrolling region or outside it, and that is what decides whether
  scrolling loses it.
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

  spex "The project timeline header stays visible while Sam reads or types" do
    scenario "The header survives a long conversation" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_966")}
      end

      given_ "a conversation with more messages than fit on screen", context do
        context =
          Enum.reduce(1..12, context, fn n, acc ->
            say_to_main_agent(acc, "message number #{n}")
          end)

        {:ok, context}
      end

      when_ "I look at the screen", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the timeline header is on the page", context do
        assert context.html =~ ~s(data-test="project-timeline"),
               "the timeline header is not on the conversation screen at all"

        {:ok, context}
      end

      then_ "and it is outside the region that scrolls", context do
        header = :binary.match(context.html, ~s(data-test="project-timeline"))
        scroll = :binary.match(context.html, ~s(data-test="conversation-scroll"))

        assert scroll != :nomatch,
               "no scrolling region is marked, so nothing here proves the header " <>
                 "survives a long conversation"

        {header_at, _} = header
        {scroll_at, _} = scroll

        assert header_at < scroll_at,
               "the header is rendered inside the scrolling region, so a long " <>
                 "conversation scrolls it out of view"

        {:ok, context}
      end
    end
  end
end

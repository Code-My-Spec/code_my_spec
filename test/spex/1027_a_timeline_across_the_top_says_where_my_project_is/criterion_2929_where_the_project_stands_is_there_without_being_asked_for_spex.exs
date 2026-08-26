defmodule CodeMySpecSpex.Story965.Criterion2929Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2929 — Where the project stands is there without being asked for.

  Rule: The timeline sits on the main agent's conversation, not on every page of
  the project.

  This started as the opposite. "A timeline that goes across the top" became a
  component in the app layout, on every project page, and seeing it there is
  what changed the answer — John: *"the phase header shows up everywhere. It
  should only show up on the chat for the main agent on the main checkout."*

  The reason it is right there and nowhere else: the timeline describes the
  whole project, and the main agent's conversation is the one place that is
  already about the whole project. On a working-copy agent's thread it would be
  describing work that agent is not doing, and on the issues page it is
  furniture.

  So the check has two halves — present on that conversation, absent from the
  pages it used to clutter.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The timeline rides the main agent's conversation, and there is no main agent
  # without somewhere to run it — `ensure_main_agent/1` refuses with
  # `:not_connected`. Same reason story 963's criteria connect one.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The timeline sits on the main agent's conversation, not on every page of the project" do
    scenario "Where the project stands is on the conversation about the project" do
      given_ :synced_context_component

      given_ "I am talking to my project's own agent", context do
        context = given_a_main_checkout(context, "spex_2929")
        path = main_conversation_path(context)

        {:ok, Map.put(context, :path, path)}
      end

      when_ "I look at that conversation", context do
        {:ok, _live, html} = live(context.conn, context.path)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the timeline is across the top of it", context do
        assert context.html =~ "data-test=\"project-timeline\"",
               "the conversation about the whole project does not say where the project " <>
                 "stands, which is the one screen it belongs on"

        timeline = :binary.match(context.html, "data-test=\"project-timeline\"") |> elem(0)
        thread = :binary.match(context.html, "data-test=\"agent-conversation\"") |> elem(0)

        assert timeline < thread,
               "the timeline renders below the conversation. Across the top is the whole " <>
                 "placement — under the transcript it is a footer nobody scrolls to."

        {:ok, context}
      end

      then_ "and it is not on the project's other pages", context do
        for path <- ~w(stories issues working-copies) do
          {:ok, _live, html} =
            live(context.conn, "/app/projects/#{context.project.id}/#{path}")

          refute html =~ "data-test=\"project-timeline\"",
                 "the timeline is still on the #{path} page. Seeing it on every page is " <>
                   "what got it moved here — it describes the whole project, and on a " <>
                   "page about one part of it it is furniture."
        end

        {:ok, context}
      end
    end
  end
end

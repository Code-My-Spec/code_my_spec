defmodule CodeMySpecSpex.Story967.Criterion2955Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2955 — Coming back gives Sam the screen he left.

  The layout is state, not a session. Closing a tab and opening it later is the
  ordinary way a founder uses this — the agent runs for hours and he looks in
  from a phone, a laptop and back again. A screen that resets to its defaults
  every time makes him re-find the thing he was watching, which is the errand
  this story exists to remove.

  `CodeMySpec.ScreenState` is the module the agent's side of this names: the
  record keyed on user and project that holds the panel layout, and the one
  thing that writes it. Called through `apply/3` because it is not written yet —
  the same shape `EpicHelpers` uses for `EpicDispatch`, and what makes these
  specs red rather than uncompilable.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The screen rides the main agent's conversation, and there is no main agent
  # without somewhere to run it.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Sam's panel layout is where he left it when he comes back to the page" do
    scenario "Coming back gives Sam the screen he left" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_967")}
      end

      given_ "a story on this project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "The one the agent picks",
            description: "A story for spex testing"
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "the dynamic tab left showing that story", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        live |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()
        render_hook(live, "dynamic_view", %{"view" => "story", "story_id" => context.story.id})

        {:ok, context}
      end

      when_ "I close the page and open it again later", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the dynamic tab is still open on that story", context do
        assert context.html =~ ~s(data-test="panel-dynamic" data-panel-open="true"),
               "the dynamic tab came back shut, so the layout was not remembered"

        assert context.html =~ ~s(data-dynamic-view="story"),
               "the dynamic tab came back on its default list rather than the story " <>
                 "it was left on"

        assert context.html =~ context.story.title,
               "the story the tab was left showing is not on the page"

        {:ok, context}
      end
    end
  end
end

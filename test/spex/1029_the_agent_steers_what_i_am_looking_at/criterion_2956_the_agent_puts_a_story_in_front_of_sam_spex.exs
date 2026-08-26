defmodule CodeMySpecSpex.Story967.Criterion2956Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2956 — The agent puts a story in front of Sam.

  The whole point of the dynamic tab. Without a producer it is a list Sam
  navigates himself, which is the errand the story removes — the agent is the
  one that knows which story it is talking about, so it is the one that should
  put it on screen.

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

  spex "The agent can change what the dynamic tab is showing" do
    scenario "The agent puts a story in front of Sam" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_967")}
      end

      given_ "a story on this project", context do
        story = Fixtures.story_fixture(context.scope, %{title: "The one the agent picks"})
        {:ok, Map.put(context, :story, story)}
      end

      given_ "the dynamic tab open", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        live |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "the agent points it at that story", context do
        apply(CodeMySpec.ScreenState, :show, [
          context.scope,
          %{view: "story", story_id: context.story.id}
        ])

        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the dynamic tab shows that story", context do
        assert context.html =~ ~s(data-dynamic-view="story"),
               "the dynamic tab did not change what it is showing"

        assert context.html =~ context.story.title,
               "the story the agent chose is not on the screen, so Sam still has to " <>
                 "go and find it"

        {:ok, context}
      end
    end
  end
end

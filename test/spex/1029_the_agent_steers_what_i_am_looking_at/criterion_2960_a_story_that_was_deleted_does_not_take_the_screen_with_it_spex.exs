defmodule CodeMySpecSpex.Story967.Criterion2960Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2960 — A story that was deleted does not take the screen with it.

  Remembered state outlives the thing it points at. A stored view naming a
  deleted story is the ordinary consequence of tidying a backlog, and the screen
  it is stored on is the one holding the conversation and the composer — so a
  raise there costs far more than the panel.

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

  spex "A remembered view whose subject is gone falls back instead of breaking" do
    scenario "A story that was deleted does not take the screen with it" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_967")}
      end

      given_ "a story on this project", context do
        story = Fixtures.story_fixture(context.scope, %{title: "The one the agent picks"})
        {:ok, Map.put(context, :story, story)}
      end

      given_ "the dynamic tab left showing that story", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        live |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()
        render_hook(live, "dynamic_view", %{"view" => "story", "story_id" => context.story.id})

        {:ok, context}
      end

      given_ "that story is deleted", context do
        # Through the tool an agent would actually use to delete one, rather
        # than reaching past it into the context.
        alias Anubis.Server.Frame
        alias CodeMySpec.McpServers.Stories.Tools.DeleteStory

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = DeleteStory.execute(%{story_id: context.story.id}, frame)

        refute response.isError,
               "the story was not deleted, so what follows tests nothing: " <>
                 inspect(response)

        {:ok, context}
      end

      when_ "I open the page again", context do
        {:ok, _live, html} = live(context.conn, main_conversation_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the screen still renders", context do
        assert context.html =~ ~s(data-test="agent-conversation"),
               "the page did not render. A stored view naming a deleted story took the " <>
                 "conversation and the composer down with it."

        {:ok, context}
      end

      then_ "and the dynamic tab says so or shows the list instead", context do
        assert context.html =~ ~s(data-test="conversation-panels"),
               "the panels are gone, so the fallback removed more than the missing story"

        refute context.html =~ context.story.title,
               "the deleted story is still being rendered by title"

        {:ok, context}
      end
    end
  end
end

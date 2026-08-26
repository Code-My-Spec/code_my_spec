defmodule CodeMySpecSpex.Story967.Criterion2959Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2959 — One project's screen does not follow Sam into another.

  A layout is about one project's work. Carrying it across means opening a new
  project on the last one's story, which is worse than a default: it looks like
  the new project's state and is not.

  This is the reason the record is keyed on user *and* project rather than
  living in `UserPreferences`, which holds one row per user.

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

  spex "A layout belongs to one project — another project opens with its own" do
    scenario "One project's screen does not follow Sam into another" do
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

      given_ "a second project of my own", context do
        other = Fixtures.project_fixture_unlinked(context.scope, %{name: "The other project"})
        {:ok, Map.put(context, :other_project, other)}
      end

      when_ "I open the other project's agent conversation", context do
        other_scope = %{context.scope | active_project_id: context.other_project.id}
        other = given_a_main_checkout(%{context | scope: other_scope}, "spex_967_other")

        {:ok, _live, html} = live(context.conn, main_conversation_path(other))

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is not showing the first project's story", context do
        refute context.html =~ context.story.title,
               "the other project opened on this project's story. A layout describes one " <>
                 "project's work, and carried across it reads as the new project's state."

        assert context.html =~ ~s(data-test="conversation-panels"),
               "the panels are not on the screen at all, so this proves nothing about " <>
                 "which project's layout they are showing"

        {:ok, context}
      end
    end
  end
end

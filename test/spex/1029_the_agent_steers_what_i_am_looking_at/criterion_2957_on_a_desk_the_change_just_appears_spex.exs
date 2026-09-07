defmodule CodeMySpecSpex.Story967.Criterion2957Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2957 — On a desk the change just appears.

  A wide screen holds every panel at once, so the agent swapping the dynamic tab
  costs nothing — nothing has to close to make room. Where a change is free it
  should simply happen, and asking permission for it would be ceremony.

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

  spex "On a wide screen the agent's change appears without Sam doing anything" do
    scenario "On a desk the change just appears" do
      given_ "a project with its own agent", context do
        {:ok, given_a_main_checkout(context, "spex_967")}
      end

      given_ "a story on this project", context do
        story = Fixtures.story_fixture(context.scope, %{title: "The one the agent picks"})
        {:ok, Map.put(context, :story, story)}
      end

      given_ "I am at my desk with the preview and the dynamic tab both open", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 1440})
        live |> element(~s([data-test="panel-tab-preview"])) |> render_click()
        live |> element(~s([data-test="panel-tab-dynamic"])) |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "the agent points the dynamic tab at a story", context do
        CodeMySpec.ScreenState.show(context.scope, %{view: "story", story_id: context.story.id})

        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the dynamic tab is showing it without my having touched anything", context do
        assert context.html =~ context.story.title,
               "the agent's change did not reach the screen, so on a desk it is no " <>
                 "better than a list"

        {:ok, context}
      end

      then_ "and the preview is still open", context do
        assert context.html =~ ~s(data-test="panel-preview" data-panel-open="true"),
               "the preview closed to make room for a change that needed no room. On a " <>
                 "wide screen both fit, which is the reason this applies here and is " <>
                 "offered on a phone."

        {:ok, context}
      end
    end
  end
end

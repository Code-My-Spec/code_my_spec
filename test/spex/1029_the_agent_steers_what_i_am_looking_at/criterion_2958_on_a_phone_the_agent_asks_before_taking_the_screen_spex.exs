defmodule CodeMySpecSpex.Story967.Criterion2958Spex do
  @moduledoc """
  Story 967 — The agent steers what I am looking at.
  Criterion 2958 — On a phone the agent asks before taking the screen.

  A phone holds one panel. Applying the agent's change there does not add
  something, it evicts something — whatever Sam was watching, possibly while he
  is part-way through typing. So the change waits behind a mark and he decides.

  The asymmetry is the point, and it is the same one that decided the
  narrow-first default: free on a desk, expensive on a phone.

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

  spex "On a narrow screen the agent's change is offered rather than applied" do
    scenario "On a phone the agent asks before taking the screen" do
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

      given_ "I am on a phone with the preview open", context do
        {:ok, live, _html} = live(context.conn, main_conversation_path(context))
        render_hook(live, "viewport", %{"width" => 390})
        live |> element(~s([data-test="panel-tab-preview"])) |> render_click()

        {:ok, Map.put(context, :live, live)}
      end

      when_ "the agent points the dynamic tab at a story", context do
        CodeMySpec.ScreenState.show(context.scope, %{view: "story", story_id: context.story.id})

        {:ok, Map.put(context, :html, render(context.live))}
      end

      then_ "the preview is still the panel I am looking at", context do
        assert context.html =~ ~s(data-test="panel-preview" data-panel-open="true"),
               "the agent closed the panel I was watching to show me something else, " <>
                 "on the one screen where that costs me the thing I had open"

        {:ok, context}
      end

      then_ "and the dynamic tab says it has something for me", context do
        assert context.html =~ ~s(data-test="panel-offer"),
               "nothing marks the dynamic tab, so the agent's choice is invisible until " <>
                 "Sam happens to open it — which is the same as not having steered at all"

        {:ok, context}
      end

      then_ "and tapping it shows me what the agent chose", context do
        html =
          context.live
          |> element(~s([data-test="panel-tab-dynamic"]))
          |> render_click()

        assert html =~ context.story.title,
               "following the offer did not show the story the agent picked"

        {:ok, context}
      end
    end
  end
end

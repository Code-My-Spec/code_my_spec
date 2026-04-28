defmodule CodeMySpecSpex.Story460.Criterion5556Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5556 — Every component type's prompt scaffold opens with
  `use <App>Spex.Case` as the only test-case `use`.

  Whether the linked component is a LiveView, controller, or any
  other type, the WriteBddSpecs prompt's testing setup section
  scaffolds `use <App>Spex.Case` and nothing else for the case
  template — no `use <App>Web.ConnCase`, no separate
  `import Phoenix.LiveViewTest` / `import Phoenix.ConnTest`. The
  colocated `<App>Spex.Case` (defined in
  `test/support/<app>_spex_case.ex`) provides every shared concern
  in one place.

  Surface: `StartTask` MCP tool (via `:bdd_task_started`). Two
  scenarios — context (`:synced_context_component`) and LiveView
  (`:synced_liveview_component`) — exercise both surface-driven
  component types we have shared givens for; together they prove the
  "regardless of type" claim. A third scenario for the controller
  branch would need a one-off `:synced_controller_component` shared
  given that no other spec uses today, so we wait for the third
  consumer to promote that.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prompt scaffold opens with `use <App>Spex.Case` for every component type" do
    scenario "context component → scaffold uses SpexCase, not bare `use SexySpex`" do
      given_ :synced_context_component

      given_ "a 1-criterion story is linked to the synced context component", context do
        story_for(context, context.component.module_name, "context")
      end

      given_ :bdd_task_started

      then_ "the scaffold uses `use <App>Spex.Case` (not bare `use SexySpex`)", context do
        assert_spex_case_scaffold(context.prompt)
        {:ok, context}
      end
    end

    scenario "LiveView component → scaffold uses SpexCase, not Web.ConnCase + LiveViewTest" do
      given_ :synced_liveview_component

      given_ "a 1-criterion story is linked to the synced LiveView component", context do
        story_for(context, context.liveview_component.module_name, "liveview")
      end

      given_ :bdd_task_started

      then_ "the scaffold uses `use <App>Spex.Case` and not the per-type ConnCase split",
            context do
        assert_spex_case_scaffold(context.prompt)
        {:ok, context}
      end
    end
  end

  defp story_for(context, module_name, type_label) do
    story =
      StoryHelpers.create_and_link(context.scope, module_name,
        title: "Story for #{type_label} scaffold assertion",
        description: "Used for the SpexCase scaffold assertion.",
        acceptance_criteria: ["single criterion for scaffold assertion"]
      )

    {:ok, Map.put(context, :story, story)}
  end

  defp assert_spex_case_scaffold(prompt) do
    assert prompt =~ ~r/use\s+\w+Spex\.Case/,
           "expected prompt to scaffold `use <App>Spex.Case`, got prompt:\n#{prompt}"

    refute prompt =~ ~r/use\s+\w+Web\.ConnCase/,
           "expected prompt NOT to scaffold per-type `use <App>Web.ConnCase`, got prompt:\n#{prompt}"

    refute prompt =~ "import Phoenix.LiveViewTest",
           "expected prompt NOT to scaffold a separate `import Phoenix.LiveViewTest` (Spex.Case provides it), got prompt:\n#{prompt}"

    refute prompt =~ "import Phoenix.ConnTest",
           "expected prompt NOT to scaffold a separate `import Phoenix.ConnTest` (Spex.Case provides it), got prompt:\n#{prompt}"
  end
end

defmodule CodeMySpecSpex.Story1083.Criterion1724Spex do
  @moduledoc """
  Story 1083 — Each story gets its design when it is picked up
  Criterion 1724 — Sam sees a story's design in the architecture view.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam sees a story's design in the architecture view", criterion: 1724 do
    scenario "the architecture view shows the story's new component with no proposal file" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the architect has just designed a story", context do
        app = context.project.module_name || "MyApp"

        component =
          ComponentHelpers.create(context.scope,
            name: "Billing",
            module_name: "#{app}Web.BillingLive",
            type: "liveview"
          )

        story =
          StoryHelpers.create_story(context.scope,
            title: "Billing adjustments",
            description: "A story designed straight through the architecture tools",
            acceptance_criteria: ["Billing is adjusted"]
          )

        session_id = "spex-#{System.unique_integer([:positive])}"
        post_hook(context, "/api/hooks/session-start", %{"session_id" => session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}

        task_response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "component_linked",
              entity_type: "story",
              entity_id: to_string(story.number),
              session_id: session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        task_id = extract_task_id!(response_text(task_response))

        _response =
          ToolLibrary.run(
            "set_story_component",
            %{story_number: story.number, module_name: component.module_name},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        _evaluate_response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: task_id, session_id: session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.merge(context, %{component: component, story: story})}
      end

      when_ "Sam opens the architecture view's namespace hierarchy", context do
        # The default tab draws boundaries, not components; the namespace tab
        # lists each component, the story's new one among them.
        {:ok, architecture_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/architecture/namespaces")

        {:ok, Map.merge(context, %{architecture_live: architecture_live, html: html})}
      end

      then_ "the story's new component is shown", context do
        assert context.html =~ context.component.module_name

        {:ok, context}
      end

      then_ "no proposal file was written", context do
        refute ExecutionContexts.file_exists?(context.execution_context, Paths.proposal_path()),
               "expected no proposal file for a patch-mode design"

        {:ok, context}
      end
    end
  end
end

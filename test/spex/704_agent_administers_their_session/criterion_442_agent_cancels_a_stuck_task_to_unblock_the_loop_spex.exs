defmodule CodeMySpecSpex.Story704.Criterion6097Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6097 — Agent cancels a stuck task to unblock the loop.

  Covers Rule 4's `cancel_task` path: an open task transitions to
  `:cancelled` without going through `evaluate_task`, and subsequent
  reads do not surface it as in-flight.

  Both assertions are observed through public agent surfaces:
  - `list_tasks` (status=active filter) — the cancelled task is absent
  - `list_tasks` (no filter) — the task appears with `:cancelled` status
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent cancels a stuck task to unblock the loop", criterion: 442 do
    scenario "cancel_task transitions task to :cancelled and removes it from active queries" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a session with one open task", context do
        session_id = "spex-6097-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}

        _ =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        # Capture the new task's id via the public list_tasks surface
        # rather than reaching into Sessions directly.
        list_resp =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: session_id, status: "active"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        list_text = TaskResponseHelpers.response_text(list_resp)
        [_, task_id] = Regex.run(~r/`([0-9a-f-]+)`/, list_text)

        {:ok, Map.merge(context, %{session_id: session_id, task_id: task_id})}
      end

      when_ "the agent calls cancel_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "cancel_task",
            %{session_id: context.session_id, task_id: context.task_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response), "expected cancel_task to succeed"
        {:ok, context}
      end

      then_ "the cancelled task no longer appears in active task queries", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: context.session_id, status: "active"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = TaskResponseHelpers.response_text(response)

        refute text =~ context.task_id,
               "expected cancelled task #{context.task_id} to be absent from list_tasks(status=active), got:\n#{text}"

        {:ok, context}
      end

      and_ "the task itself is visible with :cancelled status in an unfiltered listing",
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = TaskResponseHelpers.response_text(response)

        assert text =~ context.task_id,
               "expected cancelled task to appear in unfiltered listing, got:\n#{text}"

        assert text =~ "cancelled",
               "expected `cancelled` status in the listing, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end

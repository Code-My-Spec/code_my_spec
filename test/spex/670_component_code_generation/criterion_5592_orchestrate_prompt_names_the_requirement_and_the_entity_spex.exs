defmodule CodeMySpecSpex.Story670.Criterion5592Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5592 — Orchestrate prompt names the requirement and the
  entity.

  Surface: `get_next_requirement` MCP tool. With a context Component
  whose `implementation_file` is pending, the rendered orchestration
  line must name the requirement (`implementation_file`), the
  entity_id (the component id), and `start_task` so the parent agent
  can fan out the work without guessing. The mapper appends
  `(sub-agent start_task args: requirement_name=..., entity_type=...,
  entity_id=...)` based on the requirement's `execution_type`; the
  `dispatch/1` body itself returns just the work description.

  Sub-agent role naming (`@code-writer`) and entity_name parenthesis
  were dropped from the body during the orchestrate→dispatch rename
  (centralization deferred to story 810).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  @impl_path "lib/example_context.ex"
  @review_path ".code_my_spec/spec/example_context/design_review.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Orchestrate prompt names the requirement and the entity" do
      given_ :synced_context_in_satisfied_project

      and_ "the implementation file is removed and a design review is written",
           context do
        env = context.environment

        :ok = Environments.delete_file(env, @impl_path)
        :ok = Environments.write_file(env, @review_path, review_file_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the orchestration prompt names start_task + the requirement + the entity_id",
            context do
        prompt = context.prompt
        component_id = to_string(context.component.id)

        assert prompt =~ "start_task",
               "expected the orchestration prompt to name `start_task`, got:\n#{prompt}"

        assert prompt =~ "implementation_file",
               "expected the orchestration prompt to name the `implementation_file` requirement, got:\n#{prompt}"

        assert prompt =~ component_id,
               "expected the orchestration prompt to name the entity_id #{component_id}, got:\n#{prompt}"

        {:ok, context}
      end
    end
  end

  defp review_file_content do
    """
    # Design Review — ExampleNoImpl

    ## Overview

    Reviewed and accepted. The context is small and ready for implementation.

    ## Architecture

    Single-context boundary with one public no-op function. No child components.

    ## Integration

    Standalone — no upstream or downstream contexts at this stage.

    ## Conclusion

    Approved for implementation.
    """
  end
end

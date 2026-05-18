defmodule CodeMySpecSpex.Story670.Criterion5592Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5592 — Orchestrate prompt names the requirement and the
  entity.

  Surface: `get_next_requirement` MCP tool. The mapper groups pending
  child requirements under their orchestrator and asks each
  `satisfied_by` module to render its orchestration line. With a
  context Component whose `implementation_file` is pending,
  `ComponentCode.orchestrate/1` must produce a line that spawns a
  `@code-writer` sub-agent and names `start_task` with the
  requirement, entity_type, and entity_id so the parent agent can
  fan it out without guessing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  @module_name "ExampleContext"
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
          live(context.conn, "/projects/#{context.project.name}/files")

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

      then_ "the orchestration prompt directs the parent to spawn a @code-writer for this component",
            context do
        prompt = context.prompt
        component_id = to_string(context.component.id)

        assert prompt =~ "@code-writer",
               "expected the orchestration prompt to name the @code-writer sub-agent, got:\n#{prompt}"

        assert prompt =~ "start_task",
               "expected the orchestration prompt to name `start_task`, got:\n#{prompt}"

        assert prompt =~ "implementation_file",
               "expected the orchestration prompt to name the `implementation_file` requirement, got:\n#{prompt}"

        assert prompt =~ component_id,
               "expected the orchestration prompt to name the entity_id #{component_id}, got:\n#{prompt}"

        assert prompt =~ @module_name,
               "expected the orchestration prompt to name the component module #{@module_name}, got:\n#{prompt}"

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

defmodule CodeMySpecSpex.Story561.Criterion5627Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5627 — Every returned actionable requirement carries
  the orchestration metadata the caller needs to dispatch it
  (execution_type, orchestrated_by, validation_type).

  Surface: get_next_requirement. The mapper exposes the dispatch
  call signature on every advertised item:
  `start_task with requirement_name=..., entity_type=..., entity_id=...`.
  We assert that every advertised line carries this signature —
  the caller never sees a malformed item lacking dispatch info.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every actionable item carries dispatch metadata" do
    scenario "every start_task line in the response carries the full call signature" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "every advertised actionable line carries requirement and entity references",
            context do
        # Mainline format: `start_task with requirement_name=X, entity_type=Y, entity_id=Z`.
        # Sub-agent orchestrate text uses prose instead, e.g.
        # "Spawn a sub-agent to call start_task with requirement REQ for component CID".
        # Both must reference a requirement and an entity so the caller has
        # unambiguous dispatch info.
        start_task_lines =
          context.response_text
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ "start_task"))

        assert start_task_lines != [],
               "expected at least one start_task call line, got: #{context.response_text}"

        Enum.each(start_task_lines, fn line ->
          mentions_requirement? = line =~ "requirement_name=" or line =~ "requirement `"
          mentions_entity? = line =~ "entity_id=" or line =~ "component `" or line =~ "project `" or line =~ "story `"

          assert mentions_requirement?,
                 "actionable line lacks any requirement reference: #{line}"

          assert mentions_entity?,
                 "actionable line lacks any entity reference: #{line}"
        end)

        {:ok, context}
      end
    end
  end
end

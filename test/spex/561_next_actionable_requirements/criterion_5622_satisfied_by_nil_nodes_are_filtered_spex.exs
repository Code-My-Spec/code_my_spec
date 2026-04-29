defmodule CodeMySpecSpex.Story561.Criterion5622Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5622 — A node with satisfied_by nil is filtered from
  the actionable list — never returned even when otherwise
  actionable.

  Surface: get_next_requirement. The mapper groups actionable
  requirements under a `### TaskModuleName` heading per
  satisfied_by module. We assert that every group heading
  references a real module name (not the empty string or `nil`),
  which proves the filter holds: no node with satisfied_by=nil
  reaches the response.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "satisfied_by nil nodes never reach actionable" do
    scenario "every group heading in the response names a real task module" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "every ### group heading names a non-empty module",
            context do
        # Group headings look like `### ContextSpec` or `### ComponentTest`.
        # If a satisfied_by were nil, the heading would render as empty or `nil`.
        group_names =
          ~r/^### (.+)$/m
          |> Regex.scan(context.response_text)
          |> Enum.map(fn [_, name] -> String.trim(name) end)

        assert group_names != [],
               "expected at least one task-module group heading in the response, got: #{context.response_text}"

        Enum.each(group_names, fn name ->
          refute name == "",
                 "found an empty group heading — a satisfied_by=nil node leaked through"

          refute name =~ ~r/^nil$/i,
                 "found a `nil` group heading — a satisfied_by=nil node leaked through"
        end)

        {:ok, context}
      end
    end
  end
end

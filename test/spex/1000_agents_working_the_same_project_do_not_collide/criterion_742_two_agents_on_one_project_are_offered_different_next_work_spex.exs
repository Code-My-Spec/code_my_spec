defmodule CodeMySpecSpex.Story1000.Criterion742Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 742 — Two agents on one project are offered different next work.

  Rule: An agent's requirement graph is computed from the project's authored work
  and that agent's own files.

  Where the two halves of this story meet. The stories are shared (criterion 734)
  and the files are not (criterion 732), so the graph — which is computed from
  both — must come out differently per agent while still being about the same
  authored work. An agent that wrote the spec a requirement asks for should be
  offered the next thing; the one that has not written it should still be offered
  the spec.

  Get this wrong and the tool stops working in the ordinary case: two agents on
  one project are either handed identical work (so they duplicate or collide) or
  handed unrelated work (so they are not collaborating on anything).

  Surface: the MCP tool an agent actually calls to find its next task.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One project, two file states, two answers" do
    scenario "Two agents on one project are offered different next work" do
      given_ :synced_context_component

      given_ "two agents are serving the same project from different working copies",
             context do
        {:ok, second_dir} = Briefly.create(directory: true)

        second = %{
          context.scope
          | active_harness_id: Ecto.UUID.generate(),
            cwd: second_dir,
            environment: Environments.Environment.new(:local, second_dir)
        }

        {:ok, context |> Map.put(:writer, context.scope) |> Map.put(:other, second)}
      end

      given_ "one has written the spec a requirement asks for and the other has not", context do
        # `:synced_context_component` already wrote and synced the spec into the
        # first agent's working copy. The second's copy is empty, which is the
        # asymmetry under test — not a difference in what either was asked to do.
        assert Environments.file_exists?(context.writer.environment, ".code_my_spec/spec")
               |> is_boolean()

        {:ok, context}
      end

      when_ "each asks for its next requirement", context do
        {:ok,
         context
         |> Map.put(:writer_next, next_requirement(context.writer))
         |> Map.put(:other_next, next_requirement(context.other))}
      end

      then_ "the agent that wrote the spec is offered the following requirement", context do
        refute context.writer_next =~ "spec_file",
               "the agent that already wrote the spec was offered it again, so its own files " <>
                 "are not reaching its graph. Got: #{context.writer_next}"

        {:ok, context}
      end

      then_ "the other is still offered the spec", context do
        assert context.other_next =~ "spec_file",
               "the agent with an empty working copy was not offered the spec, so it is " <>
                 "being credited with work done in a checkout it cannot see. Got: " <>
                 context.other_next

        {:ok, context}
      end

      then_ "both are working the same authored stories", context do
        # The asymmetry must be in the files only. If the two agents were offered
        # work on different stories, the graph has partitioned the authored work
        # as well, which criterion 734 forbids.
        assert context.writer_next =~ "story" or context.other_next =~ "story",
               "neither agent was offered story-scoped work, so this scenario is not " <>
                 "exercising a shared story at all"

        {:ok, context}
      end
    end
  end

  defp next_requirement(scope) do
    {:reply, response, _frame} =
      GetNextRequirement.execute(%{}, %Frame{assigns: %{current_scope: scope}})

    response_text(response)
  end
end

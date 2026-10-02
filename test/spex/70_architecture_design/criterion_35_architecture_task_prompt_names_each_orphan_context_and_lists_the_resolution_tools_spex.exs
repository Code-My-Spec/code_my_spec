defmodule CodeMySpecSpex.Story70.Criterion5873Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5873 — Architecture task prompt names each orphan context
  and lists the resolution menu.

  Sibling of Criterion 5871. When `architecture_designed` is
  unsatisfied because an orphan context exists in the project DB, the
  re-triggered architecture task must surface that information to the
  agent. A prompt that quietly says "All user stories are currently
  satisfied by the architecture" — which is true on its face when
  every story is linked — leads the agent to conclude there is nothing
  to do and stop. The prompt has to name each orphan context and tell
  the agent how to resolve it.

  Surface: `start_task` (routes to `ArchitectureDesign.command/2`).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [design!: 4, implementation!: 2, sync!: 1]

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Architecture task prompt names each orphan context and lists the resolution tools",
    criterion: 35 do
    scenario "Architecture task prompt names each orphan and lists the resolution menu" do
      given_ :fully_satisfied_project

      and_ "an orphan context is designed, with its code",
           context do
        # Orphan must be context-shaped — `ArchitectureChecker.orphans/1`
        # only flags contexts (the architectural unit), not loose
        # modules/liveviews/etc.
        design!(context, "MyOrphanContext", [],
          description: "An orphan context with no story link and no dependency edge."
        )

        implementation!(context, "MyOrphanContext")
        sync!(context)

        {:ok, context}
      end

      and_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the architect calls start_task for architecture_designed",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "architecture_designed",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the orphan component by module name",
            context do
        assert context.prompt =~ "MyOrphanContext",
               "expected the architecture prompt to name `MyOrphanContext` as an orphan, got: #{context.prompt}"

        {:ok, context}
      end

      and_ "the prompt lists the orphan resolution menu",
           context do
        prompt = context.prompt

        assert prompt =~ ~r/set_story_component|link.*story/i,
               "expected prompt to mention linking a story (set_story_component / link a story), got: #{prompt}"

        assert prompt =~ ~r/add_dependency/,
               "expected prompt to name add_dependency for a dependency edge, got: #{prompt}"

        # Components are records (3aeb66cf): the type is set on the record, not
        # in a spec's `## Type`.
        assert prompt =~ ~r/update_component.*infrastructure/s,
               "expected prompt to name update_component for classifying as infrastructure, got: #{prompt}"

        assert prompt =~ ~r/delete_component/,
               "expected prompt to name delete_component for removing the component, got: #{prompt}"

        {:ok, context}
      end

      and_ "the prompt does not falsely declare the architecture done",
           context do
        # When every story is linked but an orphan exists, the original
        # "All user stories are currently satisfied by the architecture"
        # message is misleading on its own. Either replace it or pair
        # it with the orphan section so the agent does not stop.
        prompt = context.prompt

        # If the satisfied phrase is present, the orphan section must
        # also be present (named module + resolution menu — already
        # asserted above). The dangerous case is the satisfied phrase
        # WITHOUT any orphan diagnostic. Pattern-matched on the contains?
        # bool so the assertion stays declarative.
        assert_orphan_named_when_satisfied(
          String.contains?(
            prompt,
            "All user stories are currently satisfied by the architecture"
          ),
          prompt
        )

        {:ok, context}
      end
    end
  end

  # When the prompt declares all stories satisfied, the orphan must still
  # be named OUTSIDE that phrase. False short-circuits to :ok.
  defp assert_orphan_named_when_satisfied(false, _prompt), do: :ok

  defp assert_orphan_named_when_satisfied(true, prompt) do
    stripped =
      String.replace(prompt, "All user stories are currently satisfied by the architecture", "")

    refute Regex.run(~r/MyOrphanContext/, stripped) == nil,
           "prompt declares stories satisfied but never names the orphan — agent will stop short"
  end
end

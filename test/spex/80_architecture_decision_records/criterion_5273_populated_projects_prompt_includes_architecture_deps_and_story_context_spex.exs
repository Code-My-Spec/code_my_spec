defmodule CodeMySpecSpex.Story80.Criterion5273Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5273 — Populated project's prompt includes architecture, deps, and story context.

  When mix.exs exists, the project has at least one component, and at
  least one story, the prompt includes Architecture Overview, Current
  Dependencies, and User Stories sections — with the story title
  appearing verbatim.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The phase adapts to the project's current state" do
    scenario "Populated project's prompt includes architecture, deps, and story context" do
      given_ "a realistic mix.exs is present in the project root", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_mix_exs(context.environment)
        {:ok, context}
      end

      given_ "the project has at least one component", context do
        unique = System.unique_integer([:positive])

        component =
          ComponentHelpers.create(context.scope,
            name: "TestComponent#{unique}",
            type: "context",
            module_name: "TestComponent#{unique}",
            description: "A test component"
          )

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the project has a story titled 'Fleet manager suspends a driver card'", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Fleet manager suspends a driver card",
            description: "Allow fleet managers to suspend a driver's fuel card.",
            acceptance_criteria: ["Suspended cards cannot be used"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt contains the Architecture Overview section", context do
        assert context.prompt =~ "Architecture Overview",
               "expected Architecture Overview when the project has components"

        {:ok, context}
      end

      and_ "the prompt contains the Current Dependencies section", context do
        assert context.prompt =~ "Current Dependencies",
               "expected Current Dependencies when mix.exs is present"

        {:ok, context}
      end

      and_ "the prompt contains the User Stories section with the story title", context do
        assert context.prompt =~ "User Stories",
               "expected User Stories section when the project has stories"

        assert context.prompt =~ "Fleet manager suspends a driver card",
               "expected the story title to appear verbatim in the prompt"

        {:ok, context}
      end
    end
  end
end

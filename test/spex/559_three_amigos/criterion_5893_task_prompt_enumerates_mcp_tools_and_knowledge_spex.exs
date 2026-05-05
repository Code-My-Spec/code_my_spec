defmodule CodeMySpecSpex.Story559.Criterion5893Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5893 — When the agent calls `start_task` for
  `three_amigos_complete`, the returned prompt enumerates the
  available MCP tools (`add_rule`, `add_scenario`, `add_question`,
  `add_persona`, `link_persona_to_story`) and points the agent at
  the knowledge MCP for protocol guidance.

  Covers Rule 7 / Rule 9 from `specs.md`:
  "Task prompt enumerates available MCP tools and points to the
  knowledge MCP."

  This is a prompt-content test — proves the agent receives the
  right tool surface guidance at session start, regardless of how
  it then chooses to use it.

  Depends on:
    - `AgentTasks.ThreeAmigos.command/2` ✓
    - `StartTask` MCP tool ✓
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Three Amigos task prompt enumerates MCP tools and points to knowledge MCP" do
    scenario "start_task response prompt names the expected tools" do
      given_ "a story exists in the active project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story for prompt-content test",
            description: "Used to assert on the Three Amigos task prompt.",
            acceptance_criteria: ["Task prompt enumerates the Three Amigos MCP tools"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "session_start hook has been signalled", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for three_amigos_complete on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(context.story.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :start_response, response)}
      end

      then_ "the prompt enumerates Three Amigos MCP tools and points to the knowledge MCP",
            context do
        prompt = response_text(context.start_response)

        for tool <- ~w(add_rule add_scenario add_question add_persona link_persona_to_story) do
          assert prompt =~ tool,
                 "expected prompt to mention `#{tool}`, got #{inspect(prompt)}"
        end

        assert prompt =~ ~r/knowledge\s+MCP|semantic_search/,
               "expected prompt to point to the knowledge MCP for protocol guidance, got #{inspect(prompt)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end

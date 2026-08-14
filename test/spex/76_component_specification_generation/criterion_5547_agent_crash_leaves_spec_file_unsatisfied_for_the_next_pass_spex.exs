defmodule CodeMySpecSpex.Story76.Criterion5547Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5547 — Agent crash leaves spec_file unsatisfied for the
  next pass.

  Surface: `start_task` followed by `list_requirements`. After the agent
  task fires for spec_file but the agent exits without producing a file
  (modeled here by simply not writing anything between start_task and
  the next observation), spec_file remains unsatisfied — the graph
  is honest about the missing artifact and re-fires on the next pass.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Agent crash leaves spec_file unsatisfied for the next pass" do
      given_ "a context Component exists with no spec file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story76.NoFile",
            name: "Story76 NoFile"
          )

        :ok = ComponentHelpers.delete_stub(context.scope, component)

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start and called start_task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent exits without writing any file and the next graph pass observes state",
            context do
        # Agent crash modeled by writing nothing between start_task and observation.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "spec_file for the component remains unsatisfied", context do
        assert context.response_text =~ "Story76.NoFile",
               "expected the response to mention the component scope"

        assert context.response_text =~ ~r/\[ \]\s+\*\*spec_file\*\*/,
               "expected spec_file to stay unsatisfied — graph must not silently advance past missing artifacts"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end

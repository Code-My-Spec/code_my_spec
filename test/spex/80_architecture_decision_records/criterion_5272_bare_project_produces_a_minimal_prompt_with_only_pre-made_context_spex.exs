defmodule CodeMySpecSpex.Story80.Criterion5272Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5272 — Bare project produces a minimal prompt with only pre-made context.

  No components, no mix.exs, no stories: the prompt omits Architecture
  Overview, Current Dependencies, and User Stories sections, and only
  the auto-written pre-made ADRs surface under Existing Decisions.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The phase adapts to the project's current state" do
    scenario "Bare project produces a minimal prompt with only pre-made context" do
      given_ "the project has no components, no mix.exs, and no stories", context do
        Fixtures.reset_setup_env(context.environment)

        refute CodeMySpec.Environments.file_exists?(context.environment, "mix.exs"),
               "expected mix.exs to be absent in the bare-project fixture"

        {:ok, context}
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

      then_ "the prompt omits the Architecture Overview section", context do
        refute context.prompt =~ "Architecture Overview",
               "expected Architecture Overview to be absent when no components exist"

        {:ok, context}
      end

      and_ "the prompt omits the Current Dependencies section", context do
        refute context.prompt =~ "Current Dependencies",
               "expected Current Dependencies to be absent when mix.exs is missing"

        {:ok, context}
      end

      and_ "the prompt omits the User Stories section", context do
        refute context.prompt =~ "User Stories",
               "expected User Stories to be absent when the project has no stories"

        {:ok, context}
      end

      and_ "the prompt lists the auto-written pre-made topics under Existing Decisions",
           context do
        assert context.prompt =~ "Existing Decisions",
               "expected Existing Decisions section once pre-made ADRs are written"

        assert context.prompt =~ "elixir",
               "expected elixir to be listed as an existing pre-made decision"

        assert context.prompt =~ "phoenix",
               "expected phoenix to be listed as an existing pre-made decision"

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

defmodule CodeMySpecSpex.CodeGeneration.Rule4ScaffoldLandsCleanSpex do
  @moduledoc """
  Story: Standard stack code generation
  Rule 4 — The scaffold must land clean before completion.

  The orchestration prompt requires four mix commands after the
  generators run: `mix deps.get`, `mix compile`, `mix ecto.migrate`,
  `mix test`. Each must be named explicitly so the agent has a
  deterministic checklist before declaring the phase done.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The scaffold must land clean before completion" do
    scenario "Prompt instructs the agent to run deps.get, compile, migrate, and test after generators" do
      given_ "the project has a baseline mix.exs", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "code_generation",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt instructs the agent to run mix deps.get", context do
        assert context.prompt =~ "mix deps.get",
               "expected the prompt to instruct running mix deps.get"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to run mix compile", context do
        assert context.prompt =~ "mix compile",
               "expected the prompt to instruct running mix compile"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to run mix ecto.migrate", context do
        assert context.prompt =~ "mix ecto.migrate",
               "expected the prompt to instruct running mix ecto.migrate"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to run mix test", context do
        assert context.prompt =~ "mix test",
               "expected the prompt to instruct running mix test"

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

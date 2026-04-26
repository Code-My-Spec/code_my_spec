defmodule CodeMySpecSpex.Story598.Criterion5305Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5305 — Existing script triggers a confirmation step before overwrite.

  When code_generation.sh already exists, the prompt names the existing
  script path and instructs the agent to confirm with the user before
  overwriting.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retrofit script is rewritten from the currently-detected state" do
    scenario "Existing script triggers a confirmation step before overwrite" do
      given_ "an existing code_generation.sh is present in the project", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_full_script(context.environment)

        assert Fixtures.script_exists?(context.environment),
               "expected an existing generation script to be present"

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

      then_ "the prompt names the existing code_generation.sh path", context do
        assert context.prompt =~ ".code_my_spec/tasks/code_generation.sh",
               "expected the existing script path to be named in the prompt"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to confirm with the user before overwriting",
           context do
        assert context.prompt =~ ~r/confirm with the\s+user/i,
               "expected explicit confirmation guidance before overwrite"

        assert context.prompt =~ ~r/overwrit/i,
               "expected 'overwrite' wording in the confirmation guidance"

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

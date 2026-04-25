defmodule CodeMySpecSpex.QaIntegrationPlan.Rule2EachIntegrationCarriesVerifyScriptSpex do
  @moduledoc """
  Story: Verified third-party integrations
  Rule 2 — Each integration carries a runnable verify script.

  The orchestration prompt instructs writing `verify_{name}.sh` per
  integration with a structured-JSON output contract. OAuth2
  integrations also get an `exchange_{name}_token.sh` for the
  client-credential exchange.

  Both scenarios assert on prompt content — the agent receives a
  deterministic checklist that doesn't depend on prior project state.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each integration carries a runnable verify script" do
    scenario "Prompt names the verify-script path and JSON output contract for every integration" do
      given_ "a baseline project is in place", context do
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

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the verify-script path pattern", context do
        assert context.prompt =~ "verify_",
               "expected the prompt to mention verify_ scripts"

        assert context.prompt =~ ".code_my_spec/qa/scripts/",
               "expected the prompt to name the qa scripts directory"

        {:ok, context}
      end

      and_ "the prompt instructs reading credentials from environment variables", context do
        assert context.prompt =~ ~r/environment variables/i,
               "expected the prompt to instruct reading creds from env vars"

        {:ok, context}
      end

      and_ "the prompt names the JSON success contract", context do
        assert context.prompt =~ ~s|"status": "ok"|,
               "expected the success JSON contract to be named verbatim"

        {:ok, context}
      end

      and_ "the prompt names the JSON failure contract", context do
        assert context.prompt =~ ~s|"status": "error"|,
               "expected the failure JSON contract to be named verbatim"

        {:ok, context}
      end
    end

    scenario "OAuth2 integrations trigger an additional token-exchange script instruction" do
      given_ "a baseline project is in place", context do
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

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the OAuth2 token-exchange script path pattern", context do
        assert context.prompt =~ "exchange_",
               "expected the prompt to mention the exchange_ script for OAuth2"

        assert context.prompt =~ "_token.sh",
               "expected the OAuth2 path pattern to include _token.sh"

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

defmodule CodeMySpecSpex.Story80.Rule1PremadeAdrsAutowrittenSpex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Rule 1 — Pre-made decisions for the standard stack are auto-written
  before the agent receives the prompt.

  Covers:
  - Bootstrap developer: a fresh project ends up with the core stack
    ADRs on disk after start_task runs.
  - Retrofit/partial: a project that already has some ADRs gets only
    the missing pre-made ADRs added.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement. The tool runs `TechnicalStrategy.command/2`, which is
  the side effect this rule gates on.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Pre-made decisions are auto-written before the prompt" do
    scenario "Bootstrap developer sees the core stack ADRs after running the phase" do
      given_ "the project has no decision files on disk", context do
        Fixtures.reset_setup_env(context.environment)

        refute Fixtures.adr_exists?(context.environment, "elixir")
        refute Fixtures.adr_exists?(context.environment, "phoenix")

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

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, context}
      end

      then_ "each core stack ADR exists on disk", context do
        env = context.environment

        for topic <- ~w(elixir phoenix liveview tailwind daisyui) do
          assert Fixtures.adr_exists?(env, topic),
                 "expected ADR for #{topic} to exist after start_task"
        end

        :ok
      end
    end

    scenario "Partially-setup project fills in only the pre-made ADRs it was missing" do
      given_ "a custom elixir.md already exists with a retrofit marker", context do
        Fixtures.reset_setup_env(context.environment)

        Fixtures.with_custom_adr(
          context.environment,
          "elixir",
          "custom elixir rationale from the retrofit team"
        )

        {:ok, context}
      end

      given_ "phoenix.md does not yet exist", context do
        refute Fixtures.adr_exists?(context.environment, "phoenix")
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

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, context}
      end

      then_ "phoenix.md now exists", context do
        assert Fixtures.adr_exists?(context.environment, "phoenix"),
               "expected pre-made phoenix.md to be written"

        {:ok, context}
      end

      and_ "elixir.md still contains the retrofit marker", context do
        content = Fixtures.read_adr(context.environment, "elixir")

        assert is_binary(content), "expected elixir.md to still exist"

        assert content =~ "custom elixir rationale from the retrofit team",
               "expected the retrofit marker to survive the auto-write pass"

        {:ok, context}
      end
    end
  end
end

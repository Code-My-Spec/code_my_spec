defmodule CodeMySpecSpex.Story76.Criterion5548Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5548 — Skill-driven spec generation runs the same task.

  Surface: `POST /api/skills/start` with `skill: "develop"` and
  `subcommand: "context"`. The skill route dispatches into the same
  agent-task surface the requirements graph drives — the architect can
  trigger spec generation manually and the system applies the same
  contract (canonical path, file_valid).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Skill-driven spec generation runs the same task" do
      given_ "a context Component exists with no spec file on disk", context do
        component =
          Fixtures.component_fixture(context.scope, %{
            type: "context",
            module_name: "Story76.SkillTriggered",
            name: "Story76 SkillTriggered"
          })

        {:ok, Map.put(context, :component, component)}
      end

      when_ "the architect invokes the develop context skill on that Component", context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        response =
          context.conn
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/skills/start", %{
            "skill" => "develop",
            "subcommand" => "context",
            "module_name" => context.component.module_name,
            "external_id" => external_id
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the skill returns a prompt that drives the same context lifecycle",
            context do
        assert %{"prompt" => prompt} = context.response,
               "expected the skill response to carry a prompt for the agent"

        assert prompt =~ "Develop Context",
               "expected the orchestration prompt to enter the develop-context lifecycle"

        assert prompt =~ context.component.name,
               "expected the prompt to name the targeted component"

        assert prompt =~ "Context Spec",
               "expected the prompt to enumerate the spec phase — the same spec_file/spec_valid contract the graph runs"

        {:ok, context}
      end
    end
  end
end

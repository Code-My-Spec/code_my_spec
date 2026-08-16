defmodule CodeMySpecSpex.Story538.Criterion5113Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5113 — When the embedded directive points to a sub-agent
  task type, the agent spawns a sub-agent instead of calling
  `start_task` directly.

  Covers Rule R3 sub-clause: "based on the result; the agent then
  calls start_task itself (or delegates to a sub-agent) based on the
  result."

  ## What this asserts

  For a sub-agent task in the next-actionable wave, the rendered
  directive in the stop hook block reason must instruct the main
  agent to **spawn** the sub-agent — not append the generic
  "call `start_task` with requirement_name=..." footer that would
  invite the main agent to call start_task directly and bypass the
  sub-agent.

  The per-task `orchestrate/1` callbacks already produce the
  "Spawn a @<agent> sub-agent to call start_task ..." text. The
  mapper's job is to NOT muddy that directive with a competing
  call-start_task hint.

  ## Setup

  Use the parent-chain fixture (same pattern as 5904) to get
  component child-phase requirements (`test_file`, sub-agent
  execution_type) into the actionable frontier. With continuous mode
  on, the stop hook returns a block whose reason embeds the rendered
  directive — which we then inspect.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sub-agent directive omits the direct-start_task footer" do
    scenario "block reason tells main agent to spawn the sub-agent, not call start_task itself" do
      given_ "the project chain is past kickoff so component-level work is the frontier",
             context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a context with one schema child (the child's child-phase reqs are sub-agent typed)",
             context do
        env = context.environment

        write_context_with_review(env, "HighContext", "HighContext.Item")
        write_schema_spec_only(env, "HighContext.Item")

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        high_story =
          StoryHelpers.create_and_link(context.scope, "HighContext",
            title: "High priority parent",
            description: "As a user, I want HighContext shipped.",
            acceptance_criteria: ["HighContext renders"],
            priority: 1
          )

        :ok =
          ProjectStateFixtures.apply_story_chain_complete(context, high_story,
            persona_id: context.persona_id,
            rule_statement: "HighContext renders the priority-1 cluster",
            happy_title: "User sees the priority-1 cluster work first",
            happy_body:
              "Given the user opens HighContext\nWhen they request work\nThen HighContext.Item leads",
            failure_title: "Untethered child is excluded",
            failure_body:
              "Given parent_component_id propagation is broken\nWhen the user requests work\nThen no HighContext.Item work appears"
          )

        {:ok, context}
      end

      given_ "a session in continuous mode", context do
        session_id = "spex-5113-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        :ok = Fixtures.start_continuous_mode(context.scope, session_id)
        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the block reason tells the main agent to spawn a sub-agent", context do
        reason = context.response["reason"]

        assert is_binary(reason),
               "expected a reason string, got: #{inspect(context.response)}"

        assert reason =~ "Spawn" or reason =~ "sub-agent",
               "expected the directive to instruct spawning a sub-agent, got reason:\n#{reason}"

        {:ok, context}
      end

      and_ "the block reason does NOT append the generic call-start_task footer",
           context do
        reason = context.response["reason"]

        # The "— call `start_task` with requirement_name=..." footer
        # is the main-agent path. If it appears here, the main agent
        # would call start_task directly and bypass the sub-agent.
        refute reason =~ "— call `start_task` with requirement_name=",
               "expected NO direct-start_task footer on a sub-agent directive, got reason:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp write_context_with_review(env, module, child_module) do
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module),
        Content.context_spec(module,
          type: "context",
          dependencies: [],
          children: [%{module: child_module, type: "schema"}]
        )
      )

    :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/spec/#{module_path}/design_review.md",
        design_review_content(module)
      )
  end

  defp write_schema_spec_only(env, module) do
    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module),
        Content.child_spec(module, type: "schema")
      )
  end

  defp design_review_content(module) do
    """
    # #{module} Design Review

    ## Overview

    Reviewed the #{module} context with one schema child. Ready for
    implementation.

    ## Architecture

    - Separation of concerns is appropriate.

    ## Integration

    - No integration points with other contexts.

    ## Conclusion

    Approved.
    """
  end
end

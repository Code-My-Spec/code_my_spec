defmodule CodeMySpecSpex.Story538.Criterion5113Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5113 — When `get_next_requirement` names a sub-agent task
  type, the agent spawns a sub-agent instead of calling `start_task`
  itself.

  Covers R5(c): "the main agent may spawn a sub-agent based on
  `get_next_requirement`'s response, which resolves the session's live
  sub-agents and says whether to message one that exists or spawn a new
  one."

  ## Where the directive moved, and why it had to

  This used to read the spawn instruction out of the stop hook's block
  reason, which embedded the graph's pick. R3 changed on 2026-09-05 —
  the hook names a class and a tool call and resolves nothing on the
  agent's behalf — so there is no embedded directive left to inspect.

  That is the fix rather than the loss. The embed never carried
  sub-agent information at all: the hook called
  `format_next_requirements/1` with one argument, so `active_subagents`
  defaulted to empty, and no rendered directive it produced could ever
  have said "message the one that is already alive". Only
  `GetNextRequirement` resolves them. So the criterion asserts the
  same behaviour against the response that actually carries it.

  ## What this asserts

  The agent, having been sent to `get_next_requirement` by the menu,
  gets a directive telling it to **spawn** a sub-agent — not the
  generic "call `start_task` with requirement_name=..." footer that
  would have it bypass the sub-agent and do the work itself.

  ## Setup

  The parent-chain fixture (same pattern as 5904) puts component
  child-phase requirements (`test_file`, sub-agent execution_type) on
  the actionable frontier.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
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
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        :ok = Fixtures.start_continuous_mode(context.scope, session_id)
        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "it asks what is next, and later stops", context do
        # Asking first, because that is the order an agent works in and because
        # the loop's own emptiness check reads the requirements read model —
        # which `get_next_requirement` is what populates. A stop fired before
        # anything has computed the graph sees no work and ends the loop, so
        # this ordering is the realistic one rather than a convenience.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, next, _frame} = GetNextRequirement.execute(%{}, frame)

        stop =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, context |> Map.put(:stop, stop) |> Map.put(:next, inspect(next))}
      end

      then_ "what it is told to do next is spawn a sub-agent", context do
        assert context.next =~ "Spawn" or context.next =~ "sub-agent",
               "expected the directive to instruct spawning a sub-agent, got:\n#{context.next}"

        {:ok, context}
      end

      and_ "the directive does NOT append the generic call-start_task footer",
           context do
        # The "— call `start_task` with requirement_name=..." footer is the
        # main-agent path. If it appears on a sub-agent requirement, the main
        # agent does the work itself and the sub-agent never runs.
        refute context.next =~ "— call `start_task` with requirement_name=",
               "expected NO direct-start_task footer on a sub-agent directive, got:\n#{context.next}"

        {:ok, context}
      end

      and_ "the stop that sent it there picked nothing itself", context do
        reason = context.stop["reason"] || ""

        assert reason =~ "get_next_requirement",
               "the loop refused the stop without offering the call that opens the " <>
                 "work. Got:\n#{reason}"

        refute reason =~ "Spawn",
               "the hook resolved the requirement on the agent's behalf again. R3 " <>
                 "moved that decision to the agent, and the hook cannot make it well " <>
                 "anyway — it renders without the session's live sub-agents, so its " <>
                 "directive could never say which one to message. Got:\n#{reason}"

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

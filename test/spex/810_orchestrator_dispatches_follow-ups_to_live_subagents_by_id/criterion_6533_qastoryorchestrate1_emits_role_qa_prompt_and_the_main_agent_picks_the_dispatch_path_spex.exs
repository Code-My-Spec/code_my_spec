defmodule CodeMySpecSpex.Story810.Criterion6533Spex do
  @moduledoc """
  Story 810 — Orchestrator dispatches follow-ups to live subagents by id
  Criterion 6533 — QaStory.dispatch/1 emits `%{role: :qa, prompt: ...}`
  and the main agent picks the dispatch path.

  Rule (9cd8ba9b): each agent task's `dispatch/1` callback emits a
  STRUCTURED directive — `%{role: :qa | :coding | ..., prompt: String}` —
  not a hardcoded "Spawn @qa..." string. The main agent's playbook reads
  `:role`, consults the registry, and chooses SendMessage vs Agent
  spawn. The dispatch clause stays dispatch-agnostic.

  Surface: `get_next_requirement` MCP tool. For a `qa_complete`
  requirement, the rendered output must surface the role (so the
  orchestrator's playbook can look up `registry[:qa]`) — keyed as
  `:qa`, not just "QA" in prose. The structured form is the contract
  between the agent_task module and the main agent's dispatch logic.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dispatch directive carries the role atom so the main agent can route" do
    scenario "qa_complete requirement → directive surfaces role: :qa explicitly" do
      given_ "a session exists with a pending qa_complete requirement on a story",
             context do
        # Advance project to qa_complete frontier: all prereqs satisfied through
        # bdd_specs_passing, leaving qa_complete open as the next actionable
        # requirement so the dispatch directive surfaces the :qa role.
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the orchestrator calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the dispatch directive names the role :qa (atom-shaped, not just prose)",
            context do
        prompt = context.prompt

        # The structured directive surfaces the role atom in the rendered
        # text — either as `role: :qa`, `role=:qa`, or `:qa` adjacent to
        # the role label. Mere mention of "QA" in prose isn't enough;
        # the routing key must be unambiguous.
        assert prompt =~ ~r/role[:=]\s*:qa\b/ or prompt =~ ~r/:qa\b/,
               "expected the dispatch directive to surface the role atom `:qa` so the orchestrator's playbook can route (`registry[:qa]`), got:\n#{prompt}"

        {:ok, context}
      end

      then_ "the directive includes start_task args so the orchestrator can forward verbatim",
            context do
        prompt = context.prompt

        assert prompt =~ "start_task",
               "expected the dispatch directive to name `start_task` (the canonical prompt source), got:\n#{prompt}"

        assert prompt =~ "qa_complete",
               "expected the dispatch directive to name the `qa_complete` requirement, got:\n#{prompt}"

        {:ok, context}
      end
    end
  end
end

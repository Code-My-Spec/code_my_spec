defmodule CodeMySpecSpex.Story70.Criterion5307Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5307 — Architect removes a component from the proposal.

  When the architect deliberately removes a persisted component from the
  proposal and submits it, execution does not delete the component from
  the database. The evaluation feedback warns the architect that the
  component was removed from the proposal but preserved in the DB, with
  instructions to delete it manually if intended.

  Surface: `start_task`, `execute_proposal`, then `evaluate_task`.

  `execute_proposal` is unavoidable here rather than incidental. The scenario
  begins with a component already persisted — that is what there is to omit —
  and a project with components is being *revised*, so the session will not
  auto-execute a proposal that may predate the architect's incremental edits.
  Rewriting proposal.md and applying it is the other path the gate offers by
  name, and it is the one an architect removing a component actually takes.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Architecture design is re-runnable; execution applies an incremental diff (never delete)" do
    scenario "Architect removes a component from the proposal" do
      given_ "the project has a persisted component", context do
        app = context.project.module_name || "MyApp"

        existing_component =
          ComponentHelpers.create(context.scope,
            module_name: "#{app}.Stories.RemoteClient",
            name: "RemoteClient",
            type: "context",
            description: "Remote client for story sync — persisted in DB"
          )

        {:ok, Map.put(context, :existing_component, existing_component)}
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

      given_ "a task is started for architecture_designed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "architecture_designed",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        task_id = extract_task_id!(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect submits a proposal that omits the existing component", context do
        app = context.project.module_name || "MyApp"

        # NOTE: Stories.RemoteClient exists in the DB but is deliberately absent
        # from the proposal. Per Rule 3, execution must NOT delete it.

        # A new story is included so the proposal satisfies the "all stories linked" gate
        new_story =
          StoryHelpers.create_story(context.scope,
            title: "New story — needs architecture",
            description: "Needs architecture description",
            acceptance_criteria: ["New story criterion"]
          )

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list page
        - **Stories:** #{new_story.id}

        ## Contexts

        ### #{app}.Stories

        - **Type:** context
        - **Description:** Stories domain

        ## Dependencies

        - #{app}Web.StoryLive.Index -> #{app}.Stories
        """

        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            Fixtures.proposal_path(),
            proposal
          )

        {:reply, executed, _frame} =
          ExecuteProposal.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        {:ok, Map.put(context, :execute_response, executed)}
      end

      when_ "the architect calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "execution does not delete the existing component", context do
        # Observable at the surface twice over: the proposal applied without a
        # deletion error, and the gate that runs afterwards is satisfied. A
        # component quietly deleted would take its story links with it and the
        # evaluate below would be reporting on a different architecture.
        body = response_text(context.execute_response)

        refute context.execute_response.isError,
               "applying a proposal that omits a persisted component was refused: " <>
                 inspect(body)

        refute body =~ ~r/error.*Stories\.RemoteClient|Stories\.RemoteClient.*error/i,
               "expected no deletion error for Stories.RemoteClient, got: #{inspect(body)}"

        refute response_text(context.evaluate_response) =~ ~r/needs work/i,
               "the gate rejected the architecture after the proposal applied cleanly: " <>
                 inspect(response_text(context.evaluate_response))

        {:ok, context}
      end

      then_ "the evaluation feedback warns about the removed component", context do
        body = response_text(context.execute_response)

        assert body =~ ~r/warning|preserved|removed from proposal/i,
               "expected a warning about the component removed from the proposal, got: #{inspect(body)}"

        assert body =~ "RemoteClient",
               "expected the warning to name RemoteClient, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story70.Criterion5312Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5312 — Architect declares dependencies that all resolve.

  When every declared dependency references a component that either exists
  in the database already or is defined in the proposal, the validator
  accepts the proposal and execution persists the dependency edges.

  Surface: `start_task` then `evaluate_task`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every declared dependency must reference a known component" do
    scenario "Architect declares dependencies that all resolve" do
      given_ "the database already contains the Stories component", context do
        app = context.project.module_name || "MyApp"

        stories_component =
          ComponentHelpers.create(context.scope,
            module_name: "#{app}.Stories",
            name: "Stories",
            type: "context",
            description: "Stories domain"
          )

        {:ok, Map.put(context, :stories_component, stories_component)}
      end

      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — view story list",
            description: "Story list view",
            acceptance_criteria: ["List view criterion"]
          )

        {:ok, Map.put(context, :story, story)}
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

        task_id = extract_task_id(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect declares a dependency on the existing Stories component", context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        # StoryLive.Index depends on Stories which already exists in the DB
        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list page
        - **Stories:** #{story_id}

        ## Contexts

        ## Dependencies

        - #{app}Web.StoryLive.Index -> #{app}.Stories
        """

        :ok =
          CodeMySpec.Environments.write_file(context.environment, Paths.proposal_path(), proposal)

        {:ok, context}
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

      then_ "the validator resolves every declared dependency to a known component", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/dangling|unresolved|not found/i,
               "expected all dependencies to resolve, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected proposal to be accepted, got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed for proposal with valid dependencies, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)

  defp extract_task_id(text) do
    case Regex.run(~r/Task ID: `([^`]+)`/, text) do
      [_, task_id] -> task_id
      _ -> raise "Could not extract task ID from response: #{inspect(text)}"
    end
  end
end

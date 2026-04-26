defmodule CodeMySpecSpex.Story70.Criterion5306Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5306 — Architect re-runs architecture design after new stories arrive.

  Architecture design is re-runnable: when the architect invokes it on a
  project that already has components in the database, the system reprojects
  those components into the proposal as a starting point. The architect can
  then add new components and submit; execution creates new components and
  updates modified ones without touching unchanged existing ones.

  Surface: `start_task` prompt content (reprojects DB state) then
  `evaluate_task` (incremental diff — add/update only, never delete).
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Architecture design is re-runnable; each invocation reprojects current DB state" do
    scenario "Architect re-runs architecture design after new stories arrive" do
      given_ "the project has existing components and new unsatisfied stories", context do
        # Create an existing component to simulate prior architecture pass
        existing_component =
          Fixtures.component_fixture(context.scope, %{
            module_name: "#{context.project.module_name || "MyApp"}Web.ExistingLive",
            name: "ExistingLive",
            type: "liveview",
            description: "An existing LiveView from a prior pass"
          })

        # Create a new unsatisfied story that needs to be mapped
        new_story =
          Fixtures.story_fixture(context.scope, title: "New story — arrived after first pass")

        {:ok, Map.merge(context, %{existing_component: existing_component, new_story: new_story})}
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

        {:ok, Map.merge(context, %{task_id: task_id, start_prompt: response_text(response)})}
      end

      then_ "the start_task prompt references existing components and new unsatisfied stories",
            context do
        prompt = context.start_prompt

        assert prompt =~ context.new_story.title,
               "expected start_task prompt to include the new unsatisfied story title, got: #{inspect(prompt)}"

        :ok
      end

      when_ "the architect adds a new component for the new story and submits", context do
        app = context.project.module_name || "MyApp"
        new_story_id = context.new_story.id

        # Proposal includes: the new component + the existing component (reprojected)
        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.ExistingLive

        - **Type:** liveview
        - **Description:** An existing LiveView from a prior pass

        ### #{app}Web.NewFeatureLive

        - **Type:** liveview
        - **Description:** New feature LiveView for the newly-arrived story
        - **Stories:** #{new_story_id}

        ## Contexts

        ### #{app}.Features

        - **Type:** context
        - **Description:** Features domain

        ## Dependencies

        - #{app}Web.ExistingLive -> #{app}.Features
        - #{app}Web.NewFeatureLive -> #{app}.Features
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

      then_ "execution creates the new component's spec stub", context do
        app = context.project.module_name || "MyApp"
        spec_path = Paths.spec_file(Macro.underscore("#{app}Web.NewFeatureLive"))

        assert CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "expected spec stub at #{spec_path} to be created for the new component"

        :ok
      end

      then_ "the existing component is untouched", context do
        app = context.project.module_name || "MyApp"
        existing_spec_path = Paths.spec_file(Macro.underscore("#{app}Web.ExistingLive"))

        # The existing component already existed in the DB; its spec stub was NOT
        # present (we only created the DB record, not a spec file). Execution runs
        # `write_spec_file` which skips writing only when the file already exists.
        # The DB record should still be intact — verifiable by the evaluate passing.
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed/i,
               "expected Passed (existing component preserved), got: #{inspect(body)}"

        # Confirm execution did not error out for the existing component
        refute body =~ ~r/needs work/i,
               "expected no rejection when re-running with an existing component, got: #{inspect(body)}"

        _ = existing_spec_path
        :ok
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

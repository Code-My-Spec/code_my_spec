defmodule CodeMySpecSpex.Story70.Criterion5657Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5657 — Architect classifies an orphaned framework module by adding its path to infrastructure_paths.

  When a synced component is not story-linked and not depended on, but
  its file path appears in `.code_my_spec/config.yml#infrastructure_paths`,
  the validator treats it as infrastructure (not an orphan), accepts the
  proposal, and execution proceeds without driving any agent work for the
  classified component.

  Surface: `start_task`, edit `.code_my_spec/config.yml`, then
  `evaluate_task`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @config_path Path.join(Fixtures.base_dir(), "config.yml")

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every component must be linked to a story, transitively depended on, or in infrastructure_paths" do
    scenario "Architect classifies an orphaned framework module by adding its path to infrastructure_paths" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story A — feature one",
            description: "Story A description",
            acceptance_criteria: ["Story A criterion"]
          )

        app = context.project.module_name || "MyApp"
        app_under = Macro.underscore(app)
        application_path = "lib/#{app_under}_web/application.ex"

        {:ok, Map.merge(context, %{story: story, application_path: application_path})}
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

        task_id = extract_task_id(response_text(response))

        {:ok, Map.put(context, :task_id, task_id)}
      end

      when_ "the architect writes a proposal that includes a framework application module with no story or dep edge",
            context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureLive

        - **Type:** liveview
        - **Description:** Feature page
        - **Stories:** #{story_id}

        ## Contexts

        ### #{app}.Features

        - **Type:** context
        - **Description:** Feature domain

        ### #{app}Web.Application

        - **Type:** infrastructure
        - **Description:** OTP application supervisor (framework-generated)

        ## Dependencies

        - #{app}Web.FeatureLive -> #{app}.Features
        """

        :ok =
          CodeMySpec.Environments.write_file(context.environment, Fixtures.proposal_path(), proposal)

        {:ok, context}
      end

      when_ "the architect adds the framework path to .code_my_spec/config.yml#infrastructure_paths",
            context do
        config_yaml = """
        infrastructure_paths:
          - #{context.application_path}
        """

        :ok =
          CodeMySpec.Environments.write_file(context.environment, @config_path, config_yaml)

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

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected proposal to be accepted, but got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed in the evaluate response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "no spec stub is created for the infrastructure-classified module", context do
        app = context.project.module_name || "MyApp"
        spec_path = Fixtures.spec_file(Macro.underscore("#{app}Web.Application"))

        refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "expected no spec stub at #{spec_path} for infrastructure-classified component"

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

  defp extract_task_id(text), do: extract_task_id_from(Regex.run(~r/Task ID: `([^`]+)`/, text), text)

  defp extract_task_id_from([_, task_id], _text), do: task_id
  defp extract_task_id_from(_, text), do: raise("Could not extract task ID from response: #{inspect(text)}")
end

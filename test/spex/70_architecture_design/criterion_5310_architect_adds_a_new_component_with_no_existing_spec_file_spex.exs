defmodule CodeMySpecSpex.Story70.Criterion5310Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5310 — Architect adds a new component with no existing spec file.

  When the architect adds a component whose conventional spec path does not
  yet exist, execution writes a spec stub at that path with the expected
  module-level sections.

  Surface: `start_task` then `evaluate_task`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "New components get spec file stubs created at the conventional path" do
    scenario "Architect adds a new component with no existing spec file" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — remote story sync",
            description: "Remote story sync",
            acceptance_criteria: ["Remote sync criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "no spec file exists at the conventional path for Stories.RemoteSync", context do
        app = context.project.module_name || "MyApp"
        spec_path = Paths.spec_file(Macro.underscore("#{app}.Stories.RemoteSync"))

        refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "pre-condition failed: expected no spec file at #{spec_path} before execution"

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

      when_ "the architect adds Stories.RemoteSync as a new component and submits", context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list LiveView
        - **Stories:** #{story_id}

        ## Contexts

        ### #{app}.Stories

        - **Type:** context
        - **Description:** Stories domain

        #### Children

        - #{app}.Stories.RemoteSync (module): Remote sync module for story data

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

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected proposal to be accepted, got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed for new-component proposal, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution writes a spec stub at the conventional path", context do
        app = context.project.module_name || "MyApp"
        spec_path = Paths.spec_file(Macro.underscore("#{app}.Stories.RemoteSync"))

        assert CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "expected spec stub at #{spec_path} to be created by execution"

        {:ok, context}
      end

      then_ "the spec stub has the expected module-level sections", context do
        app = context.project.module_name || "MyApp"
        spec_path = Paths.spec_file(Macro.underscore("#{app}.Stories.RemoteSync"))

        {:ok, content} = CodeMySpec.Environments.read_file(context.environment, spec_path)

        assert content =~ "#{app}.Stories.RemoteSync",
               "expected spec stub to include the module name, got: #{inspect(content)}"

        assert content =~ "module",
               "expected spec stub to declare the component type, got: #{inspect(content)}"

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

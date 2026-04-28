defmodule CodeMySpecSpex.Story70.Criterion5290Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5290 — Architect leaves an unsatisfied story without any component link.

  When a proposal omits at least one unsatisfied story the validator rejects
  it, names the unlinked story in the feedback, and execution does not run
  (no spec stubs are created, no story-component links are persisted).

  Surface: `start_task` then `evaluate_task` (routes to
  `ArchitectureDesign.evaluate/2` which validates the proposal).
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Paths
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every unsatisfied story must be linked before the proposal can execute" do
    scenario "Architect leaves an unsatisfied story without any component link" do
      given_ "three unsatisfied stories exist on the project", context do
        story_a =
          StoryHelpers.create_story(context.scope,
            title: "Story A — feature one",
            description: "Story A description",
            acceptance_criteria: ["Story A criterion"]
          )

        story_b =
          StoryHelpers.create_story(context.scope,
            title: "Story B — feature two",
            description: "Story B description",
            acceptance_criteria: ["Story B criterion"]
          )

        story_c =
          StoryHelpers.create_story(context.scope,
            title: "Story C — feature three",
            description: "Story C description",
            acceptance_criteria: ["Story C criterion"]
          )

        {:ok,
         Map.merge(context, %{
           story_a: story_a,
           story_b: story_b,
           story_c: story_c
         })}
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

      when_ "the architect writes a proposal that links only two of three stories",
            context do
        app = context.project.module_name || "MyApp"
        story_a_id = context.story_a.id
        story_b_id = context.story_b.id

        # story_c is intentionally omitted from all surface component mappings

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.FeatureOneLive

        - **Type:** liveview
        - **Description:** Feature one page
        - **Stories:** #{story_a_id}

        ### #{app}Web.FeatureTwoLive

        - **Type:** liveview
        - **Description:** Feature two page
        - **Stories:** #{story_b_id}

        ## Contexts

        ### #{app}.Features

        - **Type:** context
        - **Description:** Core features domain

        ## Dependencies

        - #{app}Web.FeatureOneLive -> #{app}.Features
        - #{app}Web.FeatureTwoLive -> #{app}.Features
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

      then_ "the validator rejects the proposal", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected a needs-work rejection, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the rejection feedback names the unlinked story", context do
        body = response_text(context.evaluate_response)
        story_c_id = to_string(context.story_c.id)

        assert body =~ story_c_id,
               "expected rejection feedback to name story #{story_c_id}, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "no spec stubs are created", context do
        app = context.project.module_name || "MyApp"

        for module_name <- [
              "#{app}Web.FeatureOneLive",
              "#{app}Web.FeatureTwoLive",
              "#{app}.Features"
            ] do
          spec_path = Paths.spec_file(Macro.underscore(module_name))

          refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
                 "expected no spec stub at #{spec_path} when proposal was rejected"
        end

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

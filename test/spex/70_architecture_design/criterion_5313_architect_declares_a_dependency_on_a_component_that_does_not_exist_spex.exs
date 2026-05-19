defmodule CodeMySpecSpex.Story70.Criterion5313Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5313 — Architect declares a dependency on a component that does not exist.

  When a proposal declares a dependency on a component that neither exists in
  the database nor is defined elsewhere in the proposal, the validator rejects
  it as a dangling reference, names the unresolved component in the feedback,
  and execution does not run.

  Surface: `start_task` then `evaluate_task`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Every declared dependency must reference a known component" do
    scenario "Architect declares a dependency on a component that does not exist" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — view story list",
            description: "View story list",
            acceptance_criteria: ["List view criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "the database does not contain a component named Stroies", context do
        app = context.project.module_name || "MyApp"

        # Confirm no component named "Stroies" (a typo) exists
        # We rely on the clean test environment; no need for explicit assertion here.
        _ = app
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

      when_ "the architect declares a dependency on Stroies (a typo — unknown component)",
            context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        # StoryLive.Index depends on Stroies — a typo of Stories that neither exists
        # in the DB nor is defined in this proposal.
        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.StoryLive.Index

        - **Type:** liveview
        - **Description:** Story list page
        - **Stories:** #{story_id}

        ## Contexts

        ## Dependencies

        - #{app}Web.StoryLive.Index -> #{app}.Stroies
        """

        :ok =
          CodeMySpec.Environments.write_file(context.environment, Fixtures.proposal_path(), proposal)

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
               "expected rejection for dangling reference, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the rejection feedback names the unresolved reference", context do
        body = response_text(context.evaluate_response)
        app = context.project.module_name || "MyApp"

        # The feedback should mention the source component and/or the misspelled target
        assert body =~ "Stroies",
               "expected rejection feedback to name the unresolved target Stroies, got: #{inspect(body)}"

        assert body =~ "#{app}Web.StoryLive.Index",
               "expected rejection feedback to name the source component, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution does not run", context do
        app = context.project.module_name || "MyApp"

        # No spec stubs should be written when execution is blocked by validation
        spec_path = Fixtures.spec_file(Macro.underscore("#{app}Web.StoryLive.Index"))

        refute CodeMySpec.Environments.file_exists?(context.environment, spec_path),
               "expected no spec stub at #{spec_path} when proposal was rejected"

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

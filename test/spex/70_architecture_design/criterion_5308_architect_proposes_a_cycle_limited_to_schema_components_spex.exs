defmodule CodeMySpecSpex.Story70.Criterion5308Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 5308 — Architect proposes a cycle limited to schema components.

  Ecto bidirectional associations between schemas create legitimate cycles.
  When all components in a cycle are typed as `schema`, the validator
  accepts the proposal and execution proceeds without cycle warnings.

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

  spex "Cyclic dependencies among schemas are permitted (Ecto bidirectional associations)" do
    scenario "Architect proposes a cycle limited to schema components" do
      given_ "an unsatisfied story exists on the project", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — user accounts",
            description: "User accounts",
            acceptance_criteria: ["User accounts criterion"]
          )

        {:ok, Map.put(context, :story, story)}
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

      when_ "the architect declares a bidirectional schema cycle (User has_many Account, Account belongs_to User)",
            context do
        app = context.project.module_name || "MyApp"
        story_id = context.story.id

        # Accounts.User has_many Accounts.Account
        # Accounts.Account belongs_to Accounts.User
        # Both are typed as schema — Rule 4 permits this cycle

        proposal = """
        # Architecture Proposal

        ## Surface Components

        ### #{app}Web.AccountLive

        - **Type:** liveview
        - **Description:** Account management LiveView
        - **Stories:** #{story_id}

        ## Contexts

        ### #{app}.Accounts

        - **Type:** context
        - **Description:** Accounts bounded context

        #### Children

        - #{app}.Accounts.User (schema): User schema
        - #{app}.Accounts.Account (schema): Account schema

        ## Dependencies

        - #{app}Web.AccountLive -> #{app}.Accounts
        - #{app}.Accounts.User -> #{app}.Accounts.Account
        - #{app}.Accounts.Account -> #{app}.Accounts.User
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

      then_ "the validator accepts the proposal", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected schema-only cycle to be accepted, got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected Passed for schema-only cycle, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "execution proceeds without cycle warnings", context do
        body = response_text(context.evaluate_response)

        # No "circular dependency" or "cycle" error should appear for schema-only cycles
        refute body =~ ~r/circular dependency.*#{Regex.escape("Accounts.User")}|#{Regex.escape("Accounts.User")}.*circular/i,
               "expected no cycle rejection for schema-only cycle, got: #{inspect(body)}"

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

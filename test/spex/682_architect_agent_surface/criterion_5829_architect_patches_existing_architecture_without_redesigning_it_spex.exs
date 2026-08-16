defmodule CodeMySpecSpex.Story682.Criterion5829Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 5829 — Architect patches existing architecture without
  redesigning it.

  When the architect enters a session that already has a populated
  `proposal.md` and uses the incremental tools (`create_component`,
  `set_story_component`) to patch in additions, the existing proposal is
  preserved and evaluate does not auto-execute it — which would otherwise
  emit false "Component removed from proposal but preserved in DB" warnings
  for the tool-added components.

  Surface: session-start hook + start_task + tool calls + evaluate_task.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Patch-mode evaluate does not auto-execute the pre-existing proposal" do
    scenario "agent patches via tools — evaluate skips execute, no false warnings" do
      given_ "the project has an existing component and a populated proposal.md",
             context do
        proposal = Fixtures.proposal_with_context("MyApp", "Existing", "An existing context")

        {:ok, _result} =
          Fixtures.with_executed_proposal(context.scope, context.environment, proposal)

        {:ok, context}
      end

      given_ "an unsatisfied story exists", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "New story — patch mode",
            description: "Needs to land via patch mode",
            acceptance_criteria: ["Patch mode criterion"]
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

      when_ "the architect creates a new component via create_component", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          name: "NewFeature",
          module_name: "MyApp.NewFeature",
          type: "context",
          description: "Newly added in patch mode"
        }

        {:reply, response, _frame} = CreateComponent.execute(params, frame)

        refute response.isError,
               "expected create_component to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      when_ "the architect links the story to the new component", context do
        frame = %Frame{
          assigns: %{
            current_scope: context.scope,
            remote_client_opts: [plug: stub_remote_plug(), token: "test-token"]
          }
        }

        params = %{
          story_id: Integer.to_string(context.story.id),
          module_name: "MyApp.NewFeature"
        }

        {:reply, response, _frame} = SetStoryComponent.execute(params, frame)

        refute response.isError,
               "expected set_story_component to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      when_ "the architect calls evaluate_task without rewriting the proposal", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the evaluator reports passed", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work/i,
               "expected patch-mode evaluate to pass, got: #{inspect(body)}"

        assert body =~ ~r/passed/i,
               "expected 'Passed' in response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the response does not warn about MyApp.NewFeature being removed from the proposal",
            context do
        body = response_text(context.evaluate_response)

        refute body =~ "Component removed from proposal but preserved in DB: MyApp.NewFeature",
               "expected no false 'removed component' warning for MyApp.NewFeature, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the pre-existing proposal.md is unchanged on disk", context do
        {:ok, content} =
          CodeMySpec.Environments.read_file(context.environment, Fixtures.proposal_path())

        refute content =~ "MyApp.NewFeature",
               "expected proposal.md to remain unchanged (no MyApp.NewFeature added), got: #{inspect(content)}"

        assert content =~ "MyApp.Existing",
               "expected pre-existing content to remain in proposal.md, got: #{inspect(content)}"

        {:ok, context}
      end
    end
  end

  defp stub_remote_plug do
    fn conn ->
      body = Jason.encode!(%{data: []})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
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

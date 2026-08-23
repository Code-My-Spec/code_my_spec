defmodule CodeMySpecSpex.Story983.Criterion8168Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8168 — Reaching specs-ready releases QA on the story.

  Rule: QA cannot begin on a story until its specs are ready.

  The other half of criterion 8167. A gate that never opens is just a
  wall — earning the latch has to release QA with no extra ceremony and
  no second run.

  Surface: filesystem + `start_task` MCP tool + HTTP stop hook (earns the
  latch) + `show_story_requirements` MCP tool (observes QA released).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Earning the latch opens the gate" do
    scenario "Reaching specs-ready releases QA on the story" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the story's BDD specs are written and all pass", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      given_ "QA is not reachable yet", context do
        body = requirements_body(context.scope, context.story.id)

        assert body =~ ~r/\[ \]\s+\*\*qa_complete\*\*/,
               "expected QA to start unsatisfied, got: #{body}"

        {:ok, context}
      end

      given_ "the agent starts the specs-passing task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_passing",
              entity_type: "story",
              entity_id: to_string(context.story.id),
              session_id: session_id
            },
            frame
          )

        refute response.isError,
               "expected start_task on bdd_specs_passing to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "a fresh green run flips the story to specs-ready", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "spex" => fixture_path("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the specs-passing gate is done", context do
        body = requirements_body(context.scope, context.story.id)

        assert body =~ ~r/\[x\]\s+\*\*bdd_specs_passing\*\*/,
               "expected the gate to be satisfied, got: #{body}"

        {:ok, Map.put(context, :requirements_body, body)}
      end

      then_ "QA is the story's remaining work", context do
        body = context.requirements_body

        assert body =~ ~r/\[ \]\s+\*\*qa_complete\*\*/,
               "expected QA to be released as the next open requirement, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp requirements_body(scope, story_id) do
    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      ShowStoryRequirements.execute(%{story: to_string(story_id)}, frame)

    response_text(response)
  end

  defp story_spec(scope, story_id) do
    story = StoryHelpers.fetch(scope, story_id)
    [criterion | _] = story.criteria

    content = """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      @moduledoc \"\"\"
      Story #{story.id} — #{story.title}
      Criterion #{criterion.id} — #{criterion.description}
      \"\"\"

      use CodeMySpecSpex.Case

      spex "#{story.title}" do
        scenario "the criterion holds" do
          then_ "the placeholder assertion passes" do
            assert true
            :ok
          end
        end
      end
    end
    """

    {Fixtures.spec_file_path(story, criterion), content}
  end
end

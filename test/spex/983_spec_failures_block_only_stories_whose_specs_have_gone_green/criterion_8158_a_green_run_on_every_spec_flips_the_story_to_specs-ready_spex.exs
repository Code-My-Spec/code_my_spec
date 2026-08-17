defmodule CodeMySpecSpex.Story983.Criterion8158Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8158 — A green run on every spec flips the story to specs-ready.

  Rule: the specs-passing gate flips a story to specs-ready only on a
  fresh spex run showing every one of its BDD specs green.

  The agent writes the story's BDD spec at the story's own path, starts
  the specs-passing task, and fires the stop hook. The pipeline records a
  spex run from the `pipeline_clean_credo` fixture's empty `spex.jsonl`
  (zero failures), the task evaluates, and that fresh green run is what
  earns the latch.

  The spec file goes at the story-derived path (`test/spex/<story_id>_…`)
  rather than a flat one, because that is what makes the failure — or the
  absence of one — attributable to this story.

  Surface: filesystem (agent writes the spec) + `start_task` MCP tool +
  HTTP stop hook (records the run and evaluates) +
  `show_story_requirements` MCP tool (observes the flip).
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

  spex "The gate flips a story to specs-ready on a fresh green run" do
    scenario "A green run on every spec flips the story to specs-ready" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the agent writes the story's BDD spec file and it passes", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      # The specs-passing task is started directly rather than layering on
      # `:bdd_task_started` — a session has one active task, and the stop
      # hook evaluates that one. Starting bdd_specs_exist first would leave
      # WriteBddSpecs active and the gate would never run.
      given_ "the agent starts the specs-passing task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      when_ "a fresh spex run completes with every one of the story's specs green",
            context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      then_ "the story's specs are ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        body = response_text(response)

        refute response.isError,
               "expected show_story_requirements to succeed, got: #{inspect(response)}"

        assert body =~ ~r/\[x\]\s+\*\*bdd_specs_passing\*\*/,
               "expected a fresh green run to flip bdd_specs_passing to satisfied, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  # The spec lands at the story's own criterion path, so the bdd_spec
  # validator applies to it — it has to `use CodeMySpecSpex.Case`, not
  # bare `use SexySpex`, or the stop blocks on spec_validation before the
  # specs-passing gate is ever reached.
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

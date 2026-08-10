defmodule CodeMySpecSpex.Story983.Criterion8159Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8159 — One failing spec leaves the story short of ready.

  Rule: the specs-passing gate flips a story to specs-ready only on a
  fresh spex run showing every one of its BDD specs green.

  "Every one" is the load-bearing word: a run that is fresh and mostly
  green still does not earn the latch. The agent gets the failing spec
  back as work rather than a flipped flag.

  Note the two independent mechanisms in play. The spex *problem* is
  advisory here — the story never went green, so per-story enforcement
  leaves it alone. What blocks the stop is the specs-passing *task*
  failing its evaluation, which is how the agent is handed the work.

  Surface: filesystem + `start_task` MCP tool + HTTP stop hook (the
  block feedback carries the failing spec) + `show_story_requirements`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

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

  spex "A partially green run does not earn the latch" do
    scenario "One failing spec leaves the story short of ready" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the agent writes the story's BDD spec and it fails", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      given_ "the agent starts the specs-passing task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      when_ "a fresh spex run completes with that one spec red", context do
        jsonl = Fixtures.spex_run_report([{context.spec_path, "the criterion does not hold yet"}])

        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json"),
                "spex" => jsonl
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the story's specs are not ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        body = response_text(response)

        # Anchor: the story is producing requirements at all.
        assert body =~ "bdd_specs_exist",
               "expected the story to produce requirements, got: #{body}"

        assert body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "expected one failing spec to leave bdd_specs_passing unsatisfied, got: #{body}"

        {:ok, context}
      end

      then_ "the agent is given the failing spec to fix", context do
        assert context.response["decision"] == "block",
               "expected the gate to hold the agent on the failing spec, got: #{inspect(context.response)}"

        assert context.response["reason"] =~ context.spec_path,
               "expected the feedback to name the failing spec file, got: #{context.response["reason"]}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

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
          then_ "the criterion does not hold yet" do
            assert false
            :ok
          end
        end
      end
    end
    """

    {Fixtures.spec_file_path(story, criterion), content}
  end
end

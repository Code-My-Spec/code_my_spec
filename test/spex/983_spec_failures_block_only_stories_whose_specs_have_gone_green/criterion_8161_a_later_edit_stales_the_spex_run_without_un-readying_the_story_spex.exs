defmodule CodeMySpecSpex.Story983.Criterion8161Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8161 — A later edit stales the spex run without un-readying
  the story.

  Rule: once ready, a story's specs stay ready until its chain restarts
  or a user clears the flag.

  This is the regression test for `bab2f792`. The node was removed
  because its freshness guard was evaluated continuously — nearly any
  edit staled it, so it reported "analysis pending" and clamped
  downstream work. The latch fixes that by construction: freshness gates
  the *flip*, never the *state*. Once earned, an edit cannot take
  readiness away, and `qa_complete` stays reachable.

  Surface: filesystem + `start_task` MCP tool + HTTP stop hook (earns the
  latch, then stales the run) + `show_story_requirements` MCP tool
  (observes the latch holding).
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

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Freshness gates the flip, never the state" do
    scenario "A later edit stales the spex run without un-readying the story" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the agent writes the story's BDD spec file", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      given_ "the agent starts the specs-passing task", context do
        {:ok, start_specs_passing_task(context)}
      end

      given_ "a fresh green run has flipped the story to specs-ready", context do
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

        {:ok, Map.put(context, :green_response, response)}
      end

      when_ "the agent edits implementation code, staling that run", context do
        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\n  def noop, do: :changed\nend\n"
          )

        {:ok, context}
      end

      then_ "the story's specs are still ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        body = response_text(response)

        assert body =~ ~r/\[x\]\s+\*\*bdd_specs_passing\*\*/,
               "a stale run must not un-flip an earned latch, got: #{body}"

        {:ok, Map.put(context, :requirements_body, body)}
      end

      then_ "downstream work on the story stays actionable", context do
        body = context.requirements_body

        assert body =~ "qa_complete",
               "expected qa_complete to still be listed on the story, got: #{body}"

        refute body =~ ~r/analysis pending/i,
               "an earned latch must never report analysis pending, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  # A session has one active task and the stop hook evaluates that one, so
  # the specs-passing task is started directly rather than layering on
  # `:bdd_task_started` — otherwise WriteBddSpecs stays active and the
  # gate never runs.
  defp start_specs_passing_task(context) do
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

    Map.put(context, :session_id, session_id)
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

defmodule CodeMySpecSpex.Story983.Criterion8166Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8166 — A story reaches ready while another story's specs are
  red.

  Rule: the specs-passing gate counts only the story's own spec failures.

  This is the exact regression the deleted per-story scoping guarded
  against. The comment on the removed `:spex_passing` checker in
  `bab2f792` spelled it out: without story scoping, "one failing spex
  anywhere in the project blocks every story's `bdd_specs_passing` (and
  clamps every story's `qa_complete`)". Story A must be able to go green
  while story B is red.

  The spex JSONL is generated with the real story-derived paths — a
  checked-in fixture cannot carry ids assigned at runtime.

  Surface: filesystem + `start_task` MCP tool + HTTP stop hook +
  `show_story_requirements` MCP tool.
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

  spex "The gate is scoped to one story's own specs" do
    scenario "A story reaches ready while another story's specs are red" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a second story exists on the same surface", context do
        other =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Story B",
            description: "As an engineer, I want a second story whose specs are red",
            acceptance_criteria: ["Story B acceptance criterion"]
          )

        {:ok, Map.put(context, :other_story, other)}
      end

      given_ "story A's specs all pass and story B has a failing spec", context do
        {a_path, a_content} = story_spec(context.scope, context.story.id)
        {b_path, b_content} = story_spec(context.scope, context.other_story.id)

        :ok = Environments.write_file(context.environment, a_path, a_content)
        :ok = Environments.write_file(context.environment, b_path, b_content)

        {:ok, Map.merge(context, %{a_path: a_path, b_path: b_path})}
      end

      given_ "the agent starts the specs-passing task on story A", context do
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

      when_ "a run reports story B red and the stop hook fires", context do
        jsonl = Fixtures.spex_run_report([{context.b_path, "story B is not implemented yet"}])

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
                "spex" => jsonl
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "story A's specs are ready", context do
        body = requirements_body(context.scope, context.story.id)

        assert body =~ ~r/\[x\]\s+\*\*bdd_specs_passing\*\*/,
               "story A must reach ready on its own green specs, got: #{body}"

        {:ok, context}
      end

      then_ "story B's failure has no bearing on story A", context do
        body = requirements_body(context.scope, context.other_story.id)

        # Anchor: story B really is in the graph, so the assertion below
        # is about its own red specs and not a missing story.
        assert body =~ "bdd_specs_exist",
               "expected story B to produce requirements, got: #{body}"

        assert body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "story B's own failing spec must leave it unsatisfied, got: #{body}"

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

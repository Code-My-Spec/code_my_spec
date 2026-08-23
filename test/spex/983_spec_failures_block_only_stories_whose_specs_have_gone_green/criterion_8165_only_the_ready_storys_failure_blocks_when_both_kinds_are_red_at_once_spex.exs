defmodule CodeMySpecSpex.Story983.Criterion8165Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8165 — Only the ready story's failure blocks when both kinds
  are red at once.

  Rule: failing specs block the agent's stop only on stories whose specs
  are ready.

  Criteria 8163 and 8164 each prove one side in isolation. This is the
  discrimination test: with a specs-ready story and a mid-build story
  both red in the same run, the hook has to sort them. A block decision
  that fires for the right reason but also drags the mid-build failure
  into its feedback would pass both earlier criteria and still be wrong
  — the agent would go chase a spec that is red on purpose.

  ## The spex JSONL is generated, not fixtured

  Story-scoped attribution joins spex problems to files by path, and a
  story's spec path embeds its id — which is assigned at runtime. A
  static fixture can't carry both stories' real paths, so the given
  writes the JSONL with the actual paths interpolated. Same shape as
  `test/fixtures/validation/pipeline_spex_failure/spex.jsonl`, two
  entries instead of one.

  Surface: LiveView (engineer enables spex) + filesystem + HTTP stop
  hook.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @green_fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The hook sorts ready failures from mid-build failures" do
    scenario "Only the ready story's failure blocks when both kinds are red at once" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex enforcement is enabled on the project", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "a second, mid-build story exists on the same surface", context do
        mid_build =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Mid-build story",
            description: "As an engineer, I want a story whose implementation is unwritten",
            acceptance_criteria: ["Mid-build acceptance criterion"]
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, link_response, _frame} =
          SetStoryComponent.execute(
            %{
              story_id: to_string(mid_build.id),
              module_name: context.component.module_name
            },
            frame
          )

        refute link_response.isError,
               "expected set_story_component to succeed, got: #{inspect(link_response)}"

        {:ok, Map.put(context, :mid_build_story, mid_build)}
      end

      given_ "each story has a BDD spec file at its own path", context do
        ready_path = spec_path(context.scope, context.story.id)
        mid_build_path = spec_path(context.scope, context.mid_build_story.id)

        :ok = Environments.write_file(context.environment, ready_path, passing_spex())
        :ok = Environments.write_file(context.environment, mid_build_path, failing_spex())

        {:ok, Map.merge(context, %{ready_path: ready_path, mid_build_path: mid_build_path})}
      end

      given_ "a fresh green run has flipped the first story to specs-ready", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => green_fixture("compile.jsonl"),
                "exunit" => green_fixture("exunit.json"),
                "spex" => green_fixture("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :green_response, response)}
      end

      given_ "the specs-ready story then regresses too", context do
        :ok = Environments.write_file(context.environment, context.ready_path, failing_spex())
        {:ok, context}
      end

      when_ "a run reports both stories red and the stop hook fires", context do
        jsonl =
          Fixtures.spex_run_report([
            {context.ready_path, "ready story regression"},
            {context.mid_build_path, "mid-build story not implemented yet"}
          ])

        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => green_fixture("compile.jsonl"),
                "spex" => jsonl
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked on the specs-ready story's failure alone", context do
        assert context.response["decision"] == "block",
               "the specs-ready story's regression must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason)

        assert reason =~ context.ready_path,
               "block reason must name the specs-ready story's spec, got:\n#{reason}"

        {:ok, context}
      end

      then_ "the mid-build story's failure does not appear in the blocking feedback",
            context do
        refute context.response["reason"] =~ context.mid_build_path,
               "a mid-build story's failure must stay out of the block feedback, got:\n#{context.response["reason"]}"

        {:ok, context}
      end
    end
  end

  defp green_fixture(name), do: Path.expand(Path.join(@green_fixture_dir, name))

  defp spec_path(scope, story_id) do
    story = StoryHelpers.fetch(scope, story_id)
    [criterion | _] = story.criteria
    Fixtures.spec_file_path(story, criterion)
  end

  defp passing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "example context behaves" do
        scenario "the happy path holds" do
          then_ "it succeeds", context do
            assert 1 == 1
            {:ok, context}
          end
        end
      end
    end
    """
  end

  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "intentional failure" do
        scenario "asserts false" do
          then_ "fails", context do
            assert 1 == 2, "spex failure fixture"
            {:ok, context}
          end
        end
      end
    end
    """
  end
end

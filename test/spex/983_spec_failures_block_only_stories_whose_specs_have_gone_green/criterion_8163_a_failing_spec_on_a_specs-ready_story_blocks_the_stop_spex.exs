defmodule CodeMySpecSpex.Story983.Criterion8163Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8163 — A failing spec on a specs-ready story blocks the stop.

  Rule: failing specs block the agent's stop only on stories whose specs
  are ready.

  The positive half of the enforcement rule. The story earned the latch
  from a green run, so a subsequent regression is a real regression —
  the agent is held until it is fixed.

  Surface: LiveView (engineer enables spex) + filesystem (agent breaks a
  spec) + HTTP stop hook (the block decision).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @spex_path "test/spex/example_context_spex.exs"
  @green_fixture_dir "test/fixtures/validation/pipeline_clean_credo"
  @red_fixture_dir "test/fixtures/validation/pipeline_spex_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Enforcement applies to stories that have gone green" do
    scenario "A failing spec on a specs-ready story blocks the stop" do
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

      given_ "the agent writes the story's BDD spec file", context do
        :ok = Environments.write_file(context.environment, @spex_path, passing_spex())
        {:ok, context}
      end

      given_ "a fresh green run has flipped the story to specs-ready", context do
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      given_ "the story's spec later regresses", context do
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => red_fixture("compile.jsonl"),
                "spex" => red_fixture("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "a spec failure on a specs-ready story must block, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the failing spec is named in the feedback", context do
        reason = context.response["reason"]

        assert is_binary(reason)

        assert reason =~ ~r/spex/i,
               "block reason must mention spex, got:\n#{reason}"

        assert reason =~ @spex_path,
               "block reason must name the failing spec file, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp green_fixture(name), do: Path.expand(Path.join(@green_fixture_dir, name))
  defp red_fixture(name), do: Path.expand(Path.join(@red_fixture_dir, name))

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

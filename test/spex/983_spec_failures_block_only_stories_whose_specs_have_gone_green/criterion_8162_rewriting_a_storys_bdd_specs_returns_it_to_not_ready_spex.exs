defmodule CodeMySpecSpex.Story983.Criterion8162Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8162 — Rewriting a story's BDD specs returns it to not ready.

  Rule: once ready, a story's specs stay ready until its chain restarts
  or a user clears the flag.

  The counterweight to criterion 8161. An implementation edit leaves the
  latch alone, but rewriting the story's BDD specs restarts the chain —
  the contract itself changed, so the old green run says nothing about
  the new one. The story has to earn readiness again.

  Surface: filesystem (agent rewrites the spec, sync picks it up) + HTTP
  stop hook + `show_story_requirements` MCP tool.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements

  @spex_path "test/spex/example_context_spex.exs"
  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Rewriting the contract restarts the chain" do
    scenario "Rewriting a story's BDD specs returns it to not ready" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started

      given_ "the agent writes the story's BDD spec file", context do
        :ok = Environments.write_file(context.environment, @spex_path, passing_spex())
        {:ok, context}
      end

      given_ "a fresh green run has flipped the story to specs-ready", context do
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

        {:ok, Map.put(context, :green_response, response)}
      end

      when_ "the story is reopened and its BDD specs are rewritten", context do
        :ok = Environments.write_file(context.environment, @spex_path, rewritten_spex())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      then_ "the story's specs are not ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        body = response_text(response)

        # Anchor: the story still exists in the graph after the rewrite.
        assert body =~ "bdd_specs_exist",
               "expected the story to still produce requirements, got: #{body}"

        assert body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "rewriting the BDD specs must return the story to not ready, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

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

  defp rewritten_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex "example context behaves under a revised contract" do
        scenario "the revised rule holds" do
          then_ "it succeeds under the new expectation", context do
            assert 2 == 2
            {:ok, context}
          end
        end
      end
    end
    """
  end
end

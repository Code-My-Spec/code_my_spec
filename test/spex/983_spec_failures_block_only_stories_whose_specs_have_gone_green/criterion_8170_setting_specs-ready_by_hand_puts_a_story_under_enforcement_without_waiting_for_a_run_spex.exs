defmodule CodeMySpecSpex.Story983.Criterion8170Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8170 — Setting specs-ready by hand puts a story under
  enforcement without waiting for a run.

  Rule: a user can flip a story's specs-ready flag by hand from the
  project UI.

  The on-direction of the manual override: the engineer asserts
  readiness rather than earning it, and enforcement applies immediately
  — no green run required first.

  ## Open, flagged to the PM

  This direction was inferred from "yes it's manually flippable" read
  as a two-way toggle like `ready_for_dev`, not stated outright. It is
  the one place where a human can put a story under enforcement that
  the gate itself would have refused, so rule 2's "only on a fresh green
  run" is scoped to the gate rather than absolute. If the override is
  meant to be clear-only, this criterion and its rule shrink to
  criterion 8169 alone.

  Surface: StoryLive (LiveView) to set the flag + HTTP stop hook to
  observe enforcement.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  @spex_path "test/spex/example_context_spex.exs"
  @fixture_dir "test/fixtures/validation/pipeline_spex_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The engineer can assert readiness by hand" do
    scenario "Setting specs-ready by hand puts a story under enforcement without waiting for a run" do
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

      given_ "the story's specs are not ready and no green spex run exists for it",
             context do
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())

        {:ok, index_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        assert html =~ "data-test=\"story-specs-not-ready\"",
               "expected the story to start without the specs-ready latch, got: #{html}"

        {:ok, Map.put(context, :index_live, index_live)}
      end

      when_ "the user sets specs-ready from the project UI", context do
        toggled =
          context.index_live
          |> element("[data-test='toggle-story-specs-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, toggled)}
      end

      then_ "failing specs on that story block the agent's stop", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => fixture_path("compile.jsonl"),
                "spex" => fixture_path("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        assert response["decision"] == "block",
               "a hand-set specs-ready story must be enforced immediately, got: #{inspect(response)}"

        assert response["reason"] =~ ~r/spex/i,
               "block reason must mention spex, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

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

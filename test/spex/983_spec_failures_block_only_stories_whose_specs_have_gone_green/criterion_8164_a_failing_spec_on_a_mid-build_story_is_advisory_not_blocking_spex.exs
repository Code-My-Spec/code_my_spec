defmodule CodeMySpecSpex.Story983.Criterion8164Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8164 — A failing spec on a mid-build story is advisory, not
  blocking.

  Rule: failing specs block the agent's stop only on stories whose specs
  are ready.

  The whole point of the story. `ProjectConfiguration.spex` sat at `:off`
  for as long as turning it on blocked every story whose implementation
  was still unwritten — the specs are supposed to be red at that stage;
  that is what drives the implementation. With the latch in place spex
  blocks by default and mid-build stories still run free.

  "Advisory" is not "discarded": the failure is still persisted and still
  visible on the Problems page.

  The failing spec lives at the story's own path and the JSONL is
  generated to match, because a failure the harness cannot attribute to a
  story is treated as enforced — there is no story to check the latch on.

  Surface: filesystem + HTTP stop hook + Problems LiveView.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Enforcement leaves mid-build stories alone" do
    scenario "A failing spec on a mid-build story is advisory, not blocking" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      # Set explicitly rather than leaning on the default. New projects
      # default to `:off`, under which the stop would be allowed no matter
      # what the latch said — the assertion below would pass for the wrong
      # reason and prove nothing.
      given_ "spex enforcement is enabled on the project", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the story's specs are not ready because its implementation is unwritten",
             context do
        # No green run has ever been recorded for this story, so the latch
        # was never earned. The failing spec below is the expected state of
        # a story mid-build, not a regression.
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      when_ "the stop hook fires with that story's spec red", context do
        jsonl =
          write_spex_jsonl([{context.spec_path, "implementation not written yet"}])

        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      then_ "the stop is allowed", context do
        assert context.response == %{},
               "a spec failure on a story that never went green must not block, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the failure is still recorded as a visible problem", context do
        {:ok, _problems_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/problems?filter=spex")

        assert html =~ "Problems"

        assert html =~ context.spec_path,
               "the Problems page must still list the advisory spex failure, got HTML missing the spec path"

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
          then_ "the implementation is not written yet" do
            assert false
            :ok
          end
        end
      end
    end
    """

    {Fixtures.spec_file_path(story, criterion), content}
  end

  # Story attribution joins spex problems to files by path, and a story's
  # spec path carries its runtime-assigned id — so the JSONL is written
  # here with the real path rather than checked in. Same shape as
  # `test/fixtures/validation/pipeline_spex_failure/spex.jsonl`.
  defp write_spex_jsonl(entries) do
    body =
      entries
      |> Enum.map(fn {path, message} ->
        Jason.encode!(%{
          "spex" => "intentional failure",
          "scenario" => "asserts false",
          "steps" => [
            %{"type" => "then", "description" => "fails", "status" => "failed"}
          ],
          "error" => %{
            "message" => message,
            "file" => path,
            "line" => 7,
            "stacktrace" => []
          }
        })
      end)
      |> Enum.join("\n")

    path =
      Path.join(
        System.tmp_dir!(),
        "spex_983_#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, body <> "\n")
    path
  end
end

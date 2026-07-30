defmodule CodeMySpecSpex.Story983.Criterion8169Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8169 — Clearing specs-ready parks a shipped story
  mid-refactor.

  Rule: a user can flip a story's specs-ready flag by hand from the
  project UI.

  With chain-restart as the only automatic clearing path, a shipped story
  stays enforced forever — which is the point, right up until the
  engineer wants to tear its implementation apart. The manual clear is
  the escape hatch, and it has to be a flag flip rather than a spec
  rewrite: the specs are still the contract the refactor is aiming at, so
  they stay on disk.

  Mirrors the `ready_for_dev` toggle on StoryLive.Index — same page, same
  shape, a second flag.

  Surface: filesystem + `start_task` MCP tool + HTTP stop hook (earns the
  latch) + StoryLive (clears it by hand) + stop hook again (observes
  enforcement stood down).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The engineer can park a story by hand" do
    scenario "Clearing specs-ready parks a shipped story mid-refactor" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the agent writes the story's BDD spec file", context do
        {path, content} = story_spec(context.scope, context.story.id, :passing)
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

      given_ "a fresh green run has shipped the story specs-ready", context do
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
                "spex" => fixture_path("spex.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :green_response, response)}
      end

      when_ "the user clears specs-ready from the project UI", context do
        {:ok, index_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/stories")

        assert html =~ "data-test=\"story-specs-ready\"",
               "expected the shipped story to show the specs-ready marker, got: #{html}"

        toggled =
          index_live
          |> element("[data-test='toggle-story-specs-ready']")
          |> render_click()

        {:ok, Map.put(context, :toggle_html, toggled)}
      end

      then_ "failing specs on that story no longer block the agent's stop", context do
        {_path, failing} = story_spec(context.scope, context.story.id, :failing)
        :ok = Environments.write_file(context.environment, context.spec_path, failing)

        jsonl = write_spex_jsonl([{context.spec_path, "mid-refactor, expected red"}])

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

        assert response == %{},
               "a hand-parked story must not block on its failing specs, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "the story keeps its BDD spec files", context do
        assert Environments.file_exists?(context.environment, context.spec_path),
               "parking a story must not remove its BDD spec files"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp story_spec(scope, story_id, kind) do
    story = StoryHelpers.fetch(scope, story_id)
    [criterion | _] = story.criteria

    assertion = if kind == :passing, do: "assert true", else: "assert false"

    content = """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      @moduledoc \"\"\"
      Story #{story.id} — #{story.title}
      Criterion #{criterion.id} — #{criterion.description}
      \"\"\"

      use CodeMySpecSpex.Case

      spex "#{story.title}" do
        scenario "the criterion holds" do
          then_ "the placeholder assertion" do
            #{assertion}
            :ok
          end
        end
      end
    end
    """

    {Fixtures.spec_file_path(story, criterion), content}
  end

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

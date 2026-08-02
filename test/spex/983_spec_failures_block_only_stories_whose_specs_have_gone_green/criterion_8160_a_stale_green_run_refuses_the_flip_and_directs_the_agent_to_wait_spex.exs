defmodule CodeMySpecSpex.Story983.Criterion8160Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8160 — A stale green run refuses the flip and directs the
  agent to wait.

  Rule: the specs-passing gate flips a story to specs-ready only on a
  fresh spex run showing every one of its BDD specs green.

  This is the criterion that guards against repeating `bab2f792`, where
  the removed `bdd_specs_passing` node reported "analysis pending" and
  clamped downstream work. The requirement is not that staleness never
  happens — it is that staleness reads as *pending*, not as *failure*. An
  agent told "your specs failed" goes hunting for a bug that isn't there;
  an agent told "await the analysis" waits.

  ## Narrowing, flagged

  Read literally, the criterion's given ("a story whose last spex run was
  green" plus later edits) cannot hold on a story that already reached
  specs-ready — criterion 8161 fixes that a later edit leaves the latch
  ON. So the only coherent reading is a story that has NOT yet earned the
  latch: no completed run covers its current specs.

  Surface: filesystem + `start_task` and `evaluate_task` MCP tools. The
  agent evaluates the gate directly rather than through a stop hook,
  because a stop hook would run the analyzer and make the results current
  — the whole point here is the state *before* that lands.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Staleness reads as pending, not as failure" do
    scenario "A stale green run refuses the flip and directs the agent to wait" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the agent writes the story's BDD spec file", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)

        # Sync through the /files page so the spec lands as a File row.
        # No stop hook fires in this scenario, so nothing else would pick
        # it up — and without the row the gate reports "no BDD spec files"
        # instead of the pending state under test.
        {:ok, sync_live, _html} =
          live(context.conn, ~p"/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, Map.put(context, :spec_path, path)}
      end

      given_ "the agent then edits implementation code, so no completed run covers it",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\n  def noop, do: :ok\nend\n"
          )

        {:ok, context}
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

        {:ok, Map.merge(context, %{session_id: session_id, task_id: extract_task_id(response)})}
      end

      when_ "the agent works the specs-passing requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluation, response_text(response))}
      end

      then_ "the story's specs are not ready", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: to_string(context.story.id)}, frame)

        body = response_text(response)

        assert body =~ ~r/\[ \]\s+\*\*bdd_specs_passing\*\*/,
               "expected a stale run to leave bdd_specs_passing unsatisfied, got: #{body}"

        {:ok, context}
      end

      then_ "the agent is directed to await the pending analysis rather than told the specs failed",
            context do
        body = context.evaluation

        assert body =~ ~r/await_analysis|analysis pending/i,
               "expected the reason to direct the agent to await analysis, got: #{body}"

        refute body =~ ~r/BDD spec failure/i,
               "a stale run must not be reported as a spec failure, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp extract_task_id(response) do
    case Regex.run(~r/[Tt]ask [Ii][Dd]:?\s*`?([0-9a-f-]{36})`?/, response_text(response)) do
      [_, id] -> id
      _ -> nil
    end
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

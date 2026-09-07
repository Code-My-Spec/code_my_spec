defmodule CodeMySpecSpex.Story895.Criterion2406Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2406 — A regression on proven behaviour blocks whoever is stopping.

  Rule: A story whose spex have gone green blocks every working copy, assigned
  or not.

  The limit on the exemption, and the reason assignment cannot be a general
  escape hatch. Criterion 2407 is this scenario with the latch off, where the
  stop is allowed; the only difference here is that the story's specs have gone
  green, and that single fact reverses the verdict.

  ## Why green changes everything

  `specs_ready` is earned, never asserted optimistically: the specs-passing gate
  sets it on a fresh run showing every one of the story's specs green, and
  `clear_specs_ready_on_readiness_change/1` clears it whenever the story is
  released or parked. So a red spex on a latched story is not somebody's
  unfinished work — it went green once and has come back red. That is a
  regression in *this* working copy, and whose story it is has no bearing on
  whether it is broken.

  This is the same line story 983 draws with "a spec failure on a ready story
  blocks any agent in the working copy, not only the one that wrote it", one
  level out: not only the agent that wrote it, and not only the checkout it was
  assigned to.

  ## Why the second assertion exists

  Assignment now writes a sentence about whose story a finding is. On a
  regression that sentence must not appear as an excuse — an agent told "this
  belongs to the other checkout" about a genuine regression has been handed a
  reason to walk away from a broken build.

  Surface: the epic tools (placement), the project UI (the latch), the
  filesystem (the regression), and the stop hook (the decision).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.SyncProject
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.TempFile
  alias Ecto.Adapters.SQL.Sandbox

  @red_fixture_dir "test/fixtures/validation/pipeline_spex_failure"
  @their_label "the other checkout"
  @epic_name "Work that is theirs"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Only findings on stories assigned to the working copy refuse its stop" do
    scenario "A regression on proven behaviour blocks whoever is stopping" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex enforcement is enabled on the project", context do
        # `block_all`, so nothing below is allowed by the mode being lenient.
        # Whatever lets this stop through has to be the story-level rule.
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "a story assigned to another working copy", context do
        theirs = join_working_copy(context, "/tmp/spex_2406_their_copy", @their_label)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, created, _frame} =
          CreateEpic.execute(%{name: @epic_name, description: "Theirs to build"}, frame)

        {:reply, _assigned, _frame} =
          AssignStoryToEpic.execute(
            %{story_id: to_string(context.story.id), epic_name: @epic_name},
            frame
          )

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id(created), working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, context}
      end

      given_ "its spec exists and the project knows about it", context do
        [criterion | _] = context.story.criteria
        path = spex_path(context.story, criterion)

        # The scenario is named for the criterion that already exists. A spec
        # describing a scenario nobody has written down creates a criterion, and
        # a criterion that did not exist has never been green — so it clears the
        # latch (`restart_specs_chain/3`) and the regression under test quietly
        # becomes work-in-progress. That is correct behaviour and it makes this
        # premise unbuildable unless the file describes the criterion it is for.
        :ok =
          Environments.write_file(
            context.environment,
            path,
            failing_spex(criterion.description)
          )

        # Synced here rather than left for the stop hook. A spec file the
        # project has not seen yet lands a *new* criterion on the story at sync
        # time, and a criterion that did not exist has never been green — so the
        # latch below would be cleared out from under this scenario by
        # `restart_specs_chain/3`, correctly, and the regression would present
        # as work in progress. Writing the spec, syncing, and then going green is
        # also the real order of events.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, _synced, _frame} = SyncProject.execute(%{}, frame)

        {:ok, Map.put(context, :spex_path, path)}
      end

      given_ "and its spex have gone green", context do
        # Set by hand from the project UI — story 983's criterion 2201, which
        # exists so a story can be put under enforcement without waiting for a
        # run. What it stands in for here is the earned latch: a green run on
        # every one of the story's specs.
        {:ok, stories_live, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        stories_live
        |> element(~s([data-test=toggle-story-specs-ready][phx-value-id="#{context.story.id}"]))
        |> render_click()

        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => red_fixture("compile.jsonl"),
                "spex" => spex_jsonl(context.spex_path)
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook refuses the stop", context do
        assert context.response["decision"] == "block",
               "a story whose specs went green has come back red and the stop was " <>
                 "allowed because the story belongs to another checkout. The latch is " <>
                 "earned, so this is a regression rather than unfinished work, and it " <>
                 "is broken here whoever owns it. An exemption this wide would let a " <>
                 "broken build through on every checkout that did not happen to own it. " <>
                 "Got:\n#{said(context.response)}"

        {:ok, context}
      end

      then_ "and the response does not excuse the finding as another working copy's",
            context do
        reason = context.response["reason"] || ""

        assert reason =~ context.spex_path,
               "the block does not name what is broken. Got:\n#{reason}"

        refute reason =~ "that checkout's to fix",
               "the refusal carries the sentence written for advisory findings, which " <>
                 "tells the agent this is somebody else's to deal with — about a " <>
                 "regression that is blocking it right now. Naming the owner is useful; " <>
                 "offering it as a reason to walk away is not. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  # Everything the stop hook said back, whichever verdict it reached.
  #
  # A block carries its findings in `reason`; an allow carries what is still
  # true in `systemMessage`. This criterion asserts the verdict *and* what was
  # reported, and those travel in different fields.
  defp said(response) do
    (response["reason"] || "") <> "\n" <> (response["systemMessage"] || "")
  end

  # Where this story's spec for this criterion is expected to live.
  #
  # `test/spex/<number>_<story slug>/criterion_<id>_<criterion slug>_spex.exs`,
  # and it has to be exactly that: the requirement that looks for it names the
  # full path, so a file one slug away is both an unmet requirement (blocking,
  # and not the finding under test) and a spec belonging to no story.
  defp spex_path(story, criterion) do
    "test/spex/#{story.number}_#{slug(story.title)}/" <>
      "criterion_#{criterion.id}_#{slug(criterion.description)}_spex.exs"
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp epic_id(response) do
    case Regex.run(~r/\(ID: ([0-9a-f-]{36})/, inspect(response)) do
      [_, id] -> id
      nil -> flunk("could not read an epic id out of: #{inspect(response)}")
    end
  end

  defp spex_jsonl(path) do
    file = TempFile.path("spex_2406", ".jsonl")

    File.write!(
      file,
      Jason.encode!(%{
        "spex" => "intentional failure",
        "scenario" => "asserts false",
        "steps" => [%{"type" => "then", "description" => "fails", "status" => "failed"}],
        "error" => %{
          "message" => "spex failure fixture",
          "file" => path,
          "line" => 7,
          "stacktrace" => []
        }
      }) <> "\n"
    )

    file
  end

  defp red_fixture(name), do: Path.expand(Path.join(@red_fixture_dir, name))

  # Well-formed and failing. `ContentCheck` refuses a spec that does not
  # `use <App>Spex.Case` or has a scenario without Given/When/Then, and that
  # refusal is its own blocking finding — which would block this stop for a
  # reason that has nothing to do with assignment.
  defp failing_spex(scenario) do
    """
    defmodule ExampleContextSpex do
      use ExampleSpex.Case

      spex "intentional failure" do
        scenario "#{scenario}" do
          given_ "a fixture that is set up", context do
            {:ok, context}
          end

          when_ "the behaviour under test runs", context do
            {:ok, context}
          end

          then_ "it fails", context do
            assert 1 == 2, "spex failure fixture"
            {:ok, context}
          end
        end
      end
    end
    """
  end
end

defmodule CodeMySpecSpex.Story895.Criterion2407Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2407 — Work in progress elsewhere does not block here.

  Rule: Only findings on stories assigned to the working copy refuse its stop,
  while those stories' spex have not yet gone green.

  The incident this story was written from. On 2026-08-15/16 the stop hook
  blocked one agent for roughly twenty consecutive turns on devops spex
  belonging to `devops-qa-b9`, and twice more while the story was being written.
  The agent could clear them by neither fixing (outside its area, and it had
  been told to stay out) nor unlatching (shared state).

  ## What actually does the work here

  The `specs_ready` latch, and saying so is the point. 895 was parked to find
  out whether the latch made this axis unnecessary, and for blocking it largely
  did: a story whose specs have never gone green is *supposed* to be red — it is
  the red bar driving an implementation nobody has written yet — so its failures
  are advisory wherever they live, assigned or not.

  This criterion holds that line rather than adding a second one. What
  assignment contributes is the second assertion: the finding is still reported,
  and now says whose it is. Before that an agent read an advisory spex failure
  and a blocking one identically, which is the bind `b9a9f9bc` describes and
  which cost story 985 four unrelated sessions.

  Surface: the epic tools (placement), the filesystem (the failure), and the
  stop hook (the decision and what it says).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
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
    scenario "Work in progress elsewhere does not block here" do
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

      given_ "a story assigned to another working copy whose spex have never gone green",
             context do
        # Never latched: `:story_linked_to_component` leaves `specs_ready` false
        # and nothing here sets it. That is the "work in progress" half of the
        # premise, and criterion 2406 is the same shape with the latch on.
        theirs = join_working_copy(context, "/tmp/spex_2407_their_copy", @their_label)
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

      given_ "one of its spex is failing", context do
        [criterion | _] = context.story.criteria
        path = spex_path(context.story, criterion)

        :ok = Environments.write_file(context.environment, path, failing_spex())

        {:ok, Map.put(context, :spex_path, path)}
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

      then_ "the hook allows the stop", context do
        refute context.response["decision"] == "block",
               "an agent was refused its stop over a spex on another checkout's story " <>
                 "that has never been green. It can fix neither — the work is outside " <>
                 "its area — nor unlatch, because the latch is shared state. That is " <>
                 "twenty turns of an agent with nothing it is allowed to do. " <>
                 "Got:\n#{said(context.response)}"

        {:ok, context}
      end

      then_ "and the response lists the finding as present and assigned elsewhere",
            context do
        said = said(context.response)

        assert said =~ context.spex_path,
               "the stop was allowed and said nothing, so the failure is invisible in " <>
                 "the one checkout that saw it. Not blocking is not the same as not " <>
                 "reporting — the rule is loud everywhere, blocking in one place. " <>
                 "Got:\n#{said}"

        assert said =~ @their_label,
               "the finding is named without saying whose it is, which leaves the agent " <>
                 "the same two readings it had before: fix somebody else's work, or be " <>
                 "stuck behind it. Got:\n#{said}"

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
    response
    |> inspect()
    |> then(&Regex.run(~r/\(ID: ([0-9a-f-]{36})/, &1))
    |> epic_id_match(response)
  end

  defp epic_id_match([_, id], _response), do: id

  defp epic_id_match(nil, response),
    do: flunk("could not read an epic id out of: #{inspect(response)}")

  defp spex_jsonl(path) do
    file = TempFile.path("spex_2407", ".jsonl")

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
  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use ExampleSpex.Case

      spex "intentional failure" do
        scenario "asserts false" do
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

defmodule CodeMySpecSpex.Story895.Criterion2394Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2394 — A finding on someone else's story is still reported here.

  Rule: A working copy surfaces every finding about it, regardless of
  assignment.

  The rule that keeps this from becoming a demotion. John: *"the working copy
  should surface all the failures about it, but what we should be able to do is
  say this working copy should be working on these stories."* Loud everywhere,
  blocking in one place.

  ## Why that distinction is load-bearing

  Extending attribution demotion to spex was tried and reverted in `ae0a8537`,
  because it left `spex: :block_all` with no effect at all — every finding
  demoted to advisory while the mode read `:block_all` for months, and nothing
  ever blocked. `split_unattributed/2` states the principle it broke: a gate
  that quietly stops blocking is worse than one that blocks too much, because it
  is invisible.

  Assignment must not repeat that. Nothing here is hidden and nothing dropped;
  the finding is reported in the checkout where it failed, and what changes is
  only the sentence saying whose story it is. An agent that cannot see a failure
  cannot tell you the build is broken.

  ## Why the finding is named by criterion id

  A spex file is tied back to its story by its **file name** —
  `Parser.derive_criterion_id/1` reads `criterion_<id>_` and `FileSync` claims
  the path onto that criterion. That is the same route the gate uses to decide
  whose story a failure belongs to, so a scenario that invented a path outside
  the convention would produce a finding attached to no story at all, and the
  note under test would correctly stay silent.

  The run's JSONL is therefore generated here rather than taken from a fixture:
  the criterion id is only known once the story exists.

  Surface: the epic tools (placement), the filesystem (the regression), and the
  stop hook (what it reports back).
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

  spex "A working copy surfaces every finding about it, regardless of assignment" do
    scenario "A finding on someone else's story is still reported here" do
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

      given_ "the story is assigned to a second working copy", context do
        # A copy that is not this one. On a project where nothing is assigned
        # anywhere the note is deliberately silent — "this story is unassigned"
        # is true of everything and worth saying about nothing — so without a
        # real second checkout the assertion below would have nothing to find.
        theirs = join_working_copy(context, "/tmp/spex_2394_their_copy", @their_label)
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

      given_ "one of its spex is failing in this checkout", context do
        # `test/spex/<number>_<slug>/criterion_<id>_…` — the convention the gate
        # reads back to decide whose story a failure belongs to. The directory's
        # leading number is the part that identifies the story
        # (`Parser.derive_story_number/1`); a path outside the convention belongs
        # to no story at all, and the sentence under test would be silent for a
        # reason that has nothing to do with assignment.
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

      then_ "the response lists that failure among this working copy's findings", context do
        reason = said(context.response)

        assert reason =~ context.spex_path,
               "the failure happened in this checkout and this checkout did not report " <>
                 "it. Assignment decides whose stop a finding refuses; it must never " <>
                 "decide whether anyone hears about it — a gate that quietly stops " <>
                 "reporting is the `ae0a8537` failure, invisible for months. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end

      then_ "and the response names the working copy the story is assigned to", context do
        reason = said(context.response)

        assert reason =~ @their_label,
               "the finding is reported without saying whose it is, which is the state " <>
                 "an agent reads as 'somebody else's problem and I am stuck behind it'. " <>
                 "Naming the checkout is what turns it from a blocker into a fact. " <>
                 "Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  # Everything the stop hook said back, whichever verdict it reached.
  #
  # A block carries its findings in `reason`; an allow carries what is still
  # true in `systemMessage`. This criterion is about what was *reported*, not
  # about which verdict was reached — a finding on another checkout's story
  # whose specs have never gone green is advisory here and correctly does not
  # block, and it still has to be visible.
  defp said(response) do
    (response["reason"] || "") <> "\n" <> (response["systemMessage"] || "")
  end

  # Where this story's spec for this criterion is expected to live.
  #
  # `test/spex/<number>_<story slug>/criterion_<id>_<criterion slug>_spex.exs`,
  # and it has to be exactly that: the requirement that looks for it names the
  # full path, so a file one slug away is both an unmet requirement (blocking,
  # and not the finding under test) and a spec belonging to no story. Writing it
  # where the system says it goes is also what an agent does.
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

  # `CreateEpic` replies with `(ID: <uuid>, slug: <slug>)`. Stopping at the id
  # rather than the closing bracket, for the reason `EpicHelpers` records:
  # `[^)]+` swallows the slug and hands back a uuid with prose attached.
  defp epic_id(response) do
    case Regex.run(~r/\(ID: ([0-9a-f-]{36})/, inspect(response)) do
      [_, id] -> id
      nil -> flunk("could not read an epic id out of: #{inspect(response)}")
    end
  end

  # A spex run reporting one failure at `path`.
  #
  # Generated rather than taken from the fixture directory because the path has
  # to carry the story's criterion id, which does not exist until the scenario
  # runs.
  defp spex_jsonl(path) do
    file = TempFile.path("spex_2394", ".jsonl")

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

  # A spec that is *well-formed* and fails when run.
  #
  # Both halves matter. `ContentCheck` refuses a spec that does not
  # `use <App>Spex.Case` or has a scenario without Given/When/Then, and that
  # refusal is its own blocking finding — one that has nothing to do with
  # assignment and would hide the finding this criterion is about behind an
  # unrelated one.
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

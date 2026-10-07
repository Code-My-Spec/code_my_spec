defmodule CodeMySpecSpex.Story1016.Criterion2066Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2066 — A red spex on a story assigned to another copy still refuses
  this copy's stop, and the refusal names that copy.

  Rule: Every red spex refuses any copy's stop, wherever its story is assigned;
  the finding names the story's owner.

  ## Why this replaced criteria 2395 and 2407

  2395 ("Unassigned findings are visible without being blocking") and 2407
  ("Work in progress elsewhere does not block here") asserted that a red spex on
  another checkout's story was advisory *here*, on the reasoning that a story
  whose specs have never gone green is supposed to be red — it is the contract
  driving unwritten work — so its failures cannot be anybody's to fix.

  That reasoning rested on the criterion latch: `Blocking.split_by_story_enforcement/3`
  blocked a red spex only when its path had gone green before. Commit `f8d823f7e`
  (John, 2026-10-05, "Criteria no longer latch: every red spex blocks at certify
  and promote") retired it — analysis runs only at certification and promotion,
  so a red spex there is red, latched or not, and a criterion's latch had no job.
  `priv/knowledge/process/code.md` states the rule that survives: *"A red spex in
  your working copy is yours to fix whether or not you wrote it."*

  So the two criteria were asserting a rule that no longer existed, and were
  retired rather than left red: a spex asserting retired behaviour is
  indistinguishable from a regression.

  ## What survives from them

  The visibility half, and it is the half worth keeping. Criterion 893 still
  says every finding is reported here and named with its owner; this one adds
  that the owner being elsewhere is not an exemption. Loud everywhere, blocking
  everywhere — the two are no longer in tension, because nothing is demoted.

  Criterion 895 is the sibling case: the story belongs to no checkout at all,
  and that blocks everybody. Between them the rule covers the whole space — a
  story this copy holds, a story another copy holds, and a story nobody holds —
  and only the first is "yours" in the assignment sense. None of the three is an
  exemption.

  Surface: the epic tools (placement onto the other copy), the filesystem (the
  failure), and the stop hook (the decision and what it says).
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
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.RealDisk
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

  spex "A red spex on another copy's story still refuses this copy's stop", criterion: 2066 do
    scenario "A red spex on a story assigned to another copy still refuses this copy's stop" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex enforcement is enabled on the project", context do
        # `block_all`, so nothing below is allowed by the mode being lenient.
        # Whatever refuses this stop has to be the finding itself — the rule
        # this criterion states is that assignment is not an exemption, so an
        # exemption could only come from somewhere else being lenient.
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the story under test is assigned to another working copy", context do
        # The assignment is the premise, and it is made the real way — through
        # an epic placed on the other copy — because the label the refusal must
        # print is the destination checkout's, and a hand-written row would not
        # tell us whether that label is read from anywhere real.
        theirs = join_working_copy(context, "/tmp/spex_2066_their_copy", @their_label)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, created, _frame} =
          CreateEpic.execute(%{name: @epic_name, description: "Theirs to build"}, frame)

        {:reply, _assigned, _frame} =
          AssignStoryToEpic.execute(
            %{story_number: context.story.number, epic_name: @epic_name},
            frame
          )

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id(created), working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, context}
      end

      given_ "one of its spex is failing, and the project knows the file", context do
        [criterion | _] = context.story.criteria
        path = spex_path(context.story, criterion)

        # The scenario is named for the criterion that already exists. A spec
        # describing a scenario nobody has written down creates a criterion, and
        # a criterion that did not exist has never been green — so it reopens the
        # specs chain and the finding under test becomes a different finding.
        # Correct behaviour, and it makes this premise unbuildable unless the file
        # describes the criterion it is for.
        :ok = Environments.write_file(context.environment, path, failing_spex(criterion.id))
        HarnessHooks.write_file(context, path, failing_spex(criterion.id))

        {:ok, Map.put(context, :spex_path, path)}
      end

      when_ "the agent attempts to stop", context do
        HarnessHooks.land_analysis(context, "compiler", red_fixture("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", spex_jsonl(context.spex_path))

        # The stopping agent did work this session. An agent that edited nothing
        # is blocked by nothing, whatever is red, so without this the refusal
        # asserted below could not happen and the scenario would be testing the
        # attribution rule instead of this one.
        :ok = record_edit(context, context.spex_path)

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook refuses the stop", context do
        assert context.response["decision"] == "block",
               "a failing spec on another checkout's story let this stop through. " <>
                 "Assignment says whose work it is; it does not say whether the " <>
                 "failure is real, and a red spex is red wherever the story lives " <>
                 "(f8d823f7e). Exempting another copy's work is the `ae0a8537` " <>
                 "failure again — a gate that reads as enabled and quietly blocks " <>
                 "nothing. Got:\n#{said(context.response)}"

        {:ok, context}
      end

      then_ "and the refusal names the copy the story is assigned to", context do
        reason = context.response["reason"] || ""

        assert reason =~ context.spex_path,
               "the block does not name what is broken. Got:\n#{reason}"

        assert reason =~ @their_label,
               "the agent is stopped over work owned by another checkout and is not " <>
                 "told whose it is, which leaves it with the discouraging reading " <>
                 "only: somebody else's problem that it is somehow stuck behind. " <>
                 "The rule is loud everywhere and blocking everywhere, and the second " <>
                 "half of that is naming the owner. Got:\n#{reason}"

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
  # full path, so a file one slug away is both an unmet requirement and a spec
  # belonging to no story.
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
    file = TempFile.path("spex_2066", ".jsonl")

    RealDisk.write!(
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
  # refusal is its own blocking finding — which would refuse this stop for a
  # reason that has nothing to do with assignment.
  defp failing_spex(number) do
    """
    defmodule ExampleContextSpex do
      use ExampleSpex.Case

      spex "intentional failure", criterion: #{number} do
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

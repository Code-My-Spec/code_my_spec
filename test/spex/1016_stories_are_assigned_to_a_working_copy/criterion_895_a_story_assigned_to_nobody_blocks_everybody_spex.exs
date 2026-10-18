defmodule CodeMySpecSpex.Story895.Criterion2396Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2396 — A story assigned to nobody blocks everybody.

  Rule: Only findings on stories assigned to the working copy refuse its stop,
  while those stories' spex have not yet gone green.

  The direction of the default, on the blocking side. Unassigned is not
  "nobody's" — it is *everybody's*. John: *"if a harness is assigned stories, it
  should get its assigned stories and all unassigned stories. Unassigned stories
  should surface to all working copies."* A story in the shared backlog is one
  this checkout could be working, so its failures are this checkout's to answer
  for.

  ## Why it must not be the other way round

  Reading unassigned as "belongs to no one, so blocks no one" is the reading
  that quietly disarms the gate: almost every story in a project is unassigned,
  so an exemption there is an exemption for nearly everything. That is
  `ae0a8537` again — `spex: :block_all` reading as enabled while nothing ever
  blocked, for months, invisibly. `split_unattributed/2` states the principle
  directly: a gate that quietly stops blocking is worse than one that blocks too
  much, because it cannot be seen.

  ## What the second working copy is doing here

  Making assignment mean something on this project. The note that names an
  owner is deliberately silent where nobody has assigned anything, because
  "this story is unassigned" is then true of every story and worth saying about
  none of them. So a second checkout holds some other work, and the story under
  test stays in the shared backlog — which is the premise.

  Surface: the epic tools (so assignment is in use at all), the project UI (the
  latch), the filesystem (the regression), and the stop hook.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.TempFile
  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  @red_fixture_dir "test/fixtures/validation/pipeline_spex_failure"
  @their_label "the other checkout"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Only findings on stories assigned to the working copy refuse its stop", criterion: 895 do
    scenario "A story assigned to nobody blocks everybody" do
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

      given_ "some other work on this project is assigned to a second working copy",
             context do
        # Assignment in use somewhere, so "unassigned" carries information. The
        # story under test is deliberately not this one — it stays in the shared
        # backlog, which is what the criterion is about.
        theirs = join_working_copy(context, "/tmp/spex_2396_their_copy", @their_label)
        epic = EpicHelpers.propose(context, "Work that is theirs", stories: 1)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic, working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, context}
      end

      given_ "a story assigned to no working copy at all, whose spec the project knows",
             context do
        [criterion | _] = context.story.criteria
        path = spex_path(context.story, criterion)

        # The scenario is named for the criterion that already exists. A spec
        # describing a scenario nobody has written down creates a criterion, and
        # a criterion that did not exist has never been green — so it clears the
        # latch (`restart_specs_chain/3`) and the finding under test becomes
        # work-in-progress. Correct behaviour, and it makes this premise
        # unbuildable unless the file describes the criterion it is for.
        :ok =
          Environments.write_file(
            context.environment,
            path,
            failing_spex(criterion)
          )

        HarnessHooks.write_file(context, path, failing_spex(criterion))

        # Synced now rather than left to the stop hook, for the same reason: a
        # file the project has not seen yet lands a new criterion at sync time
        # and clears the latch out from under the scenario. Write, sync, go
        # green is also the real order of events.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        _synced =
          ToolLibrary.run(
            "sync_project",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :spex_path, path)}
      end

      when_ "the agent attempts to stop", context do
        HarnessHooks.land_analysis(context, "compiler", red_fixture("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", spex_jsonl(context.spex_path))

        # The stopping agent did work this session: one that edited nothing is
        # blocked by nothing (story 894), whatever is red.
        :ok = record_edit(context, context.spex_path)

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook refuses the stop", context do
        assert context.response["decision"] == "block",
               "a failing spec on a story nobody has claimed let the stop through. " <>
                 "Unassigned means every working copy, not none — and since almost " <>
                 "every story in a project is unassigned, exempting them exempts nearly " <>
                 "everything, which is a gate that reads as enabled and does nothing. " <>
                 "Got:\n#{said(context.response)}"

        {:ok, context}
      end

      then_ "and the response names the story as unassigned", context do
        reason = context.response["reason"] || ""

        assert reason =~ context.spex_path,
               "the block does not name what is broken. Got:\n#{reason}"

        assert reason =~ "no checkout",
               "the agent is stopped over work it never picked up and is not told why " <>
                 "that is its problem. 'Assigned to no checkout' is the fact that makes " <>
                 "the refusal make sense rather than look arbitrary. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

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

  defp spex_jsonl(path) do
    file = TempFile.path("spex_2396", ".jsonl")

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
  # refusal is its own blocking finding — which would block this stop for a
  # reason that has nothing to do with assignment.
  # Names its criterion, as a synced spex does (`Files.SpecBinding`).
  defp failing_spex(criterion) do
    """
    defmodule ExampleContextSpex do
      use ExampleSpex.Case

      spex "intentional failure", criterion: #{Map.get(criterion, :number) || criterion.id} do
        scenario "#{criterion.description}" do
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

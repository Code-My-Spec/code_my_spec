defmodule CodeMySpecSpex.Story983.Criterion8165Spex do
  @moduledoc """
  Story 983 — Spec failures block only stories whose specs have gone green
  Criterion 8165 — Only the ready story's failure blocks when both kinds
  are red at once.

  Rule: failing specs block the agent's stop only on stories whose specs
  are ready.

  Criteria 8163 and 8164 each prove one side in isolation. This is the
  discrimination test: with a specs-ready story and a mid-build story
  both red in the same run, the hook has to sort them. A block decision
  that fires for the right reason but also drags the mid-build failure
  into its feedback would pass both earlier criteria and still be wrong
  — the agent would go chase a spec that is red on purpose.

  ## The spex JSONL is generated, not fixtured

  Story-scoped attribution joins spex problems to files by path, and a
  story's spec path embeds its id — which is assigned at runtime. A
  static fixture can't carry both stories' real paths, so the given
  writes the JSONL with the actual paths interpolated. Same shape as
  `test/fixtures/validation/pipeline_spex_failure/spex.jsonl`, two
  entries instead of one.

  Surface: LiveView (engineer enables spex) + filesystem + HTTP stop
  hook.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  @green_fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The hook sorts ready failures from mid-build failures", criterion: 736 do
    scenario "Only the ready story's failure blocks when both kinds are red at once" do
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

      given_ "a second, mid-build story exists on the same surface", context do
        mid_build =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Mid-build story",
            description: "As an engineer, I want a story whose implementation is unwritten",
            acceptance_criteria: ["Mid-build acceptance criterion"]
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, link_response, _frame} =
          SetStoryComponent.execute(
            %{
              story_number: mid_build.number,
              module_name: context.component.module_name
            },
            frame
          )

        refute link_response.isError,
               "expected set_story_component to succeed, got: #{inspect(link_response)}"

        {:ok, Map.put(context, :mid_build_story, mid_build)}
      end

      given_ "each story has a BDD spec file at its own path", context do
        {ready_path, ready_number} = spec_path(context.scope, context.story.id)
        {mid_build_path, mid_build_number} = spec_path(context.scope, context.mid_build_story.id)

        :ok = Environments.write_file(context.environment, ready_path, passing_spex(ready_number))
        HarnessHooks.write_file(context, ready_path, passing_spex(ready_number))

        :ok =
          Environments.write_file(
            context.environment,
            mid_build_path,
            failing_spex(mid_build_number)
          )

        HarnessHooks.write_file(context, mid_build_path, failing_spex(mid_build_number))

        # Already synced: `write_file/3` returns once the harness has reported
        # each file, so the latch set below is not cleared by a later sync
        # reading these as freshly rewritten specs (criterion 2193).

        {:ok,
         Map.merge(context, %{
           ready_path: ready_path,
           mid_build_path: mid_build_path
         })}
      end

      # By hand, through the project UI (criterion 8170). A green stop does not
      # flip the latch — only the specs-passing evaluation and the UI do — and
      # this scenario is about what happens once one story is ready, not how
      # it got there.
      given_ :criterion_latched_by_promotion

      # The ready story regresses without its spec being edited — its
      # implementation broke. Editing the spec would be a rewrite, and a
      # rewrite un-readies the story (criterion 2193).
      given_ "the agent's change to the shared implementation broke the ready story",
             context do
        # The regression this criterion sorts is the agent's own: it edited the
        # implementation both stories sit on. Without an edit the session owns
        # nothing and nothing it is shown can block it (story 894).
        :ok =
          Environments.write_file(
            context.environment,
            "lib/example_context.ex",
            "defmodule ExampleContext do\n  @moduledoc false\n  def broken, do: :changed\nend\n"
          )

        :ok = record_edit(context, "lib/example_context.ex")
        {:ok, context}
      end

      when_ "a run reports both stories red and the stop hook fires", context do
        jsonl =
          Fixtures.spex_run_report([
            {context.ready_path, "ready story regression"},
            {context.mid_build_path, "mid-build story not implemented yet"}
          ])

        HarnessHooks.land_analysis(context, "compiler", green_fixture("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", jsonl)

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked on the specs-ready story's failure alone", context do
        assert context.response["decision"] == "block",
               "the specs-ready story's regression must block, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason)

        assert reason =~ context.ready_path,
               "block reason must name the specs-ready story's spec, got:\n#{reason}"

        {:ok, context}
      end

      then_ "the mid-build story's failure does not appear in the blocking feedback",
            context do
        refute context.response["reason"] =~ context.mid_build_path,
               "a mid-build story's failure must stay out of the block feedback, got:\n#{context.response["reason"]}"

        {:ok, context}
      end
    end
  end

  defp green_fixture(name), do: Path.expand(Path.join(@green_fixture_dir, name))

  # The path, and the criterion number the spec names on its `spex` call.
  defp spec_path(scope, story_id) do
    story = StoryHelpers.fetch(scope, story_id)
    [criterion | _] = story.criteria
    {Fixtures.spec_file_path(story, criterion), criterion.id}
  end

  defp passing_spex(number) do
    """
    defmodule ExampleContextSpex do
      use CodeMySpecSpex.Case

      spex "example context behaves", criterion: #{number} do
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

  defp failing_spex(number) do
    """
    defmodule ExampleContextSpex do
      use CodeMySpecSpex.Case

      spex "intentional failure", criterion: #{number} do
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

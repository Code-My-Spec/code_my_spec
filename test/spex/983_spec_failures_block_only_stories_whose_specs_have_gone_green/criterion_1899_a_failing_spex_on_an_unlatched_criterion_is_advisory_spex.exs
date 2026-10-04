defmodule CodeMySpecSpex.Story983.Criterion1899Spex do
  @moduledoc """
  Story 983 — Criterion 1899: a failing spex whose criterion is not latched
  is advisory, not blocking.

  The per-criterion counterpart to criterion 735. A criterion that has never
  gone green on a certifying run has no latch to regress from — its failure
  is the expected state of unfinished work, not a thing to hold the agent on.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.ReadyForQaHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.StoryHelpers

  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "An unlatched criterion's failure is advisory", criterion: 1899 do
    scenario "a failing spec on a never-latched criterion does not block" do
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

      given_ "the criterion's spec is red, and has never been latched", context do
        {path, content} = story_spec(context.scope, context.story.id)
        :ok = Environments.write_file(context.environment, path, content)
        HarnessHooks.write_file(context, path, content)
        {:ok, Map.put(context, :spec_path, path)}
      end

      when_ "the stop hook fires", context do
        jsonl = Fixtures.spex_run_report([{context.spec_path, "implementation not written yet"}])

        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))
        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "spex", jsonl)

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is allowed", context do
        assert context.response == %{},
               "a failure on a criterion that was never latched must not block, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the criterion carries no latch", context do
        story = Stories.get_story!(context.scope, context.story.id)
        [criterion | _] = story.criteria
        assert criterion_latch(context, criterion) == nil
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
      use CodeMySpecSpex.Case

      spex \"#{story.title}\", criterion: #{criterion.id} do
        scenario \"the criterion holds\" do
          then_ \"the implementation is not written yet\" do
            assert false
            :ok
          end
        end
      end
    end
    """

    {Fixtures.spec_file_path(story, criterion), content}
  end
end

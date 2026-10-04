defmodule CodeMySpecSpex.Story983.Criterion1900Spex do
  @moduledoc """
  Story 983 — Criterion 1900: with a latched and an unlatched criterion both
  failing at once, only the latched criterion's failure blocks.

  The per-criterion counterpart to criterion 736, which discriminates by
  story. This discriminates within a single story: a latched criterion that
  regressed, and a second, never-latched criterion that is red for the
  ordinary reason unfinished work is red. The hook has to sort them even
  though both live on the same story and the same run.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  @fixture_dir "test/fixtures/validation/pipeline_clean_credo"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The hook sorts a latched criterion's failure from an unlatched one's",
       criterion: 1900 do
    scenario "both criteria red at once; only the latched one blocks" do
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

      given_ "a second criterion exists on the same story, never latched", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddCriterion.execute(
            %{
              story_number: context.story.number,
              description: "A second, unfinished criterion"
            },
            frame
          )

        refute response.isError, inspect(response)

        story = Stories.get_story(context.scope, context.story.id)
        [latched] = Enum.reject(story.criteria, &(&1.description =~ "second"))
        [unlatched] = Enum.filter(story.criteria, &(&1.description =~ "second"))

        {:ok,
         Map.merge(context, %{
           story: story,
           latched_criterion: latched,
           unlatched_criterion: unlatched
         })}
      end

      given_ "each criterion has a BDD spec file at its own path", context do
        latched_path = Fixtures.spec_file_path(context.story, context.latched_criterion)
        unlatched_path = Fixtures.spec_file_path(context.story, context.unlatched_criterion)

        :ok =
          Environments.write_file(
            context.environment,
            latched_path,
            passing_spex(context.latched_criterion)
          )

        HarnessHooks.write_file(context, latched_path, passing_spex(context.latched_criterion))

        :ok =
          Environments.write_file(
            context.environment,
            unlatched_path,
            failing_spex(context.unlatched_criterion)
          )

        HarnessHooks.write_file(
          context,
          unlatched_path,
          failing_spex(context.unlatched_criterion)
        )

        {:ok, Map.merge(context, %{latched_path: latched_path, unlatched_path: unlatched_path})}
      end

      given_ :criterion_latched_by_promotion

      given_ "the latched criterion's own implementation regresses", context do
        :ok =
          Environments.write_file(
            context.environment,
            context.latched_path,
            failing_spex(context.latched_criterion)
          )

        HarnessHooks.write_file(
          context,
          context.latched_path,
          failing_spex(context.latched_criterion)
        )

        {:ok, context}
      end

      when_ "a run reports both criteria red and the stop hook fires", context do
        jsonl =
          Fixtures.spex_run_report([
            {context.latched_path, "latched criterion regression"},
            {context.unlatched_path, "unfinished criterion, expected red"}
          ])

        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", jsonl)

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked on the latched criterion's failure alone", context do
        assert context.response["decision"] == "block",
               "the latched criterion's regression must block, got: #{inspect(context.response)}"

        reason = context.response["reason"] || ""

        assert reason =~ context.latched_path,
               "block reason must name the latched criterion's spec, got:\n#{reason}"

        {:ok, context}
      end

      then_ "the unlatched criterion's failure does not appear in the blocking feedback",
            context do
        reason = context.response["reason"] || ""

        refute reason =~ context.unlatched_path,
               "an unlatched criterion's failure must stay out of the block feedback, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp passing_spex(criterion) do
    """
    defmodule ExampleContextSpex do
      use CodeMySpecSpex.Case

      spex \"example context behaves\", criterion: #{criterion.id} do
        scenario \"the happy path holds\" do
          then_ \"it succeeds\", context do
            assert 1 == 1
            {:ok, context}
          end
        end
      end
    end
    """
  end

  defp failing_spex(criterion) do
    """
    defmodule ExampleContextSpex do
      use CodeMySpecSpex.Case

      spex \"intentional failure\", criterion: #{criterion.id} do
        scenario \"asserts false\" do
          then_ \"fails\", context do
            assert 1 == 2, \"spex failure fixture\"
            {:ok, context}
          end
        end
      end
    end
    """
  end
end

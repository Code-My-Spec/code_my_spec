defmodule CodeMySpecSpex.Story983.Criterion1901Spex do
  @moduledoc """
  Story 983 — Criterion 1901: a latched criterion's failure blocks whoever is
  stopping, in any working copy.

  Not the same axis criterion 903 already covers (attribution: a different
  *session* on the same copy). This one is about the copy itself: the latch
  lives on the criterion's own row, not on anything local to a checkout, so a
  working copy that has never run this criterion's spex green a single time
  — no certifying run, no stop that ever earned anything here — still blocks
  on its regression, because the fact that it is latched did not originate
  on this disk.

  The given sets the latch directly rather than through this copy's own
  pipeline, which is the point: nothing in this scenario ever produces a
  green run on *this* harness.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.HarnessHooks

  @spex_path "test/spex/example_context_spex.exs"
  @fixture_dir "test/fixtures/validation/pipeline_spex_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A criterion's latch blocks regardless of where it was earned", criterion: 1901 do
    scenario "this copy never certified the criterion itself, yet its regression blocks" do
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

      given_ "the criterion's spec exists on this checkout", context do
        :ok = Environments.write_file(context.environment, @spex_path, passing_spex())
        HarnessHooks.write_file(context, @spex_path, passing_spex())
        {:ok, context}
      end

      # Set directly, standing in for a certifying run that happened on
      # whichever copy actually earned it — this harness has produced no
      # green run of its own for this criterion before this point.
      given_ :criterion_latched_by_promotion

      given_ "the spec regresses here, on a copy that never certified it", context do
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())
        HarnessHooks.write_file(context, @spex_path, failing_spex())
        {:ok, context}
      end

      when_ "the agent attempts to stop", context do
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", fixture_path("spex.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked even though this copy never earned the latch itself",
            context do
        assert context.response["decision"] == "block",
               "a latched criterion's regression must block any copy, got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "the refusal names the failing spec", context do
        reason = context.response["reason"] || ""

        assert reason =~ @spex_path,
               "a block an agent cannot act on is no block at all. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp passing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex \"example context behaves\" do
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

  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use SexySpex

      spex \"intentional failure\" do
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

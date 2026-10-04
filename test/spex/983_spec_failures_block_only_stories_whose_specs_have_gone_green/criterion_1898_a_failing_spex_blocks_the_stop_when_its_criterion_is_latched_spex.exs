defmodule CodeMySpecSpex.Story983.Criterion1898Spex do
  @moduledoc """
  Story 983 — Criterion 1898: a failing spex blocks the stop (and promotion)
  when its criterion is latched.

  The per-criterion counterpart to criterion 734, which blocks on the whole
  story's `specs_ready` flag. This exercises the stop path; the equivalent
  promotion refusal is the same successor to `story_spex_pass/3` that
  criterion 1896's own scenario exercises from the other side (showing it
  let a red *unlatched* criterion through).
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

  spex "A latched criterion's regression blocks the stop", criterion: 1898 do
    scenario "a failing spec on a latched criterion blocks" do
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

      given_ "the agent writes the criterion's BDD spec file", context do
        :ok = Environments.write_file(context.environment, @spex_path, passing_spex())
        :ok = record_edit(context, @spex_path)
        {:ok, context}
      end

      given_ :criterion_latched_by_promotion

      given_ "the criterion's spec later regresses", context do
        :ok = Environments.write_file(context.environment, @spex_path, failing_spex())
        HarnessHooks.write_file(context, @spex_path, failing_spex())
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))
        HarnessHooks.land_analysis(context, "spex", fixture_path("spex.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked, naming the failing spec", context do
        assert context.response["decision"] == "block",
               "a regression on a latched criterion must block, got: #{inspect(context.response)}"

        reason = context.response["reason"] || ""

        assert reason =~ @spex_path,
               "block reason must name the failing spec file, got:\n#{reason}"

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

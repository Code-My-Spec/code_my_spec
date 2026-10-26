defmodule CodeMySpecSpex.Story555.Criterion2428Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors.
  Criterion 2428 — a stop does not launch a subprocess analyzer; findings
  already persisted by an analysis run remain until a newer run lands.

  The analyzer outputs are landed before the hook fires. The stop itself has
  no command cassette: attempting to run mix compile, credo, test or spex
  from that hook fails instead of silently satisfying this specification.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpecSpex.SharedGivens

  @dirty_output Path.expand("test/fixtures/validation/pipeline_compile_error/compile.jsonl")
  @clean_output Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A stop never runs a subprocess analyzer and recorded problems persist until a newer run lands",
    criterion: 2428 do
    scenario "the stop leaves the last recorded compiler finding intact" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "a completed compiler run recorded a problem for the existing file", context do
        use_cmd_cassette "pipeline_compile_error", record: :none do
          Fixtures.land_outputs(context.scope,
            compile_output_file: @dirty_output,
            await: true
          )
        end

        {:ok, context}
      end

      when_ "the stop hook fires without another analysis run", context do
        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})
        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "the stop is allowed and the recorded problem is still visible", context do
        assert context.stop_response == %{}

        assert {:ok, problems} =
                 ToolLibrary.run("list_problems", %{"source" => "compiler"}, %{
                   scope: context.scope
                 })

        assert problems =~ "lib/example_context.ex"
        {:ok, context}
      end
    end

    scenario "a newer recorded run replaces the old finding" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "an older compiler run recorded a problem", context do
        use_cmd_cassette "pipeline_compile_error", record: :none do
          Fixtures.land_outputs(context.scope, compile_output_file: @dirty_output, await: true)
        end

        {:ok, context}
      end

      when_ "a clean compiler run lands and the stop hook fires", context do
        use_cmd_cassette "clean", record: :none do
          Fixtures.land_outputs(context.scope, compile_output_file: @clean_output, await: true)
        end

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})
        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "the newer run has cleared the prior finding without the stop starting analysis",
            context do
        assert context.stop_response == %{}

        assert {:ok, problems} =
                 ToolLibrary.run("list_problems", %{"source" => "compiler"}, %{
                   scope: context.scope
                 })

        refute problems =~ "lib/example_context.ex"
        {:ok, context}
      end
    end
  end
end

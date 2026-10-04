defmodule CodeMySpecSpex.Story670.Criterion5590Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5590 — Analyzer-written problem after command fired
  surfaces in evaluation.

  Surface: stop hook drives Validation + TaskEvaluator. The temporal
  sequence we're spec'ing is: (1) `start_task` fires `command/2` with
  a clean component snapshot, (2) the agent writes a malformed code
  file, (3) the stop-hook pipeline runs the compile analyzer, which
  persists a problem against the code file in the database, and
  (4) `evaluate/2` reloads the component and reads the just-persisted
  problem. The block proves the freshest persisted state — not the
  in-memory snapshot from when command fired — drives the gate.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.HarnessHooks

  @code_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation", criterion: 335 do
    scenario "Analyzer-written problem after command fired surfaces in evaluation" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the agent has signalled session start and command/2 fired with a clean component",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      given_ "between command and evaluate, the agent writes a malformed code file", context do
        :ok =
          Environments.write_file(
            context.environment,
            @code_path,
            """
            defmodule ExampleContext do
              # malformed — missing `end`
            """
          )

        :ok = record_edit(context, @code_path)

        {:ok, context}
      end

      when_ "the stop hook fires — the analyzer persists a problem, evaluate reloads and reads it",
            context do
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the just-persisted problem appears in the blocking feedback", context do
        assert context.response["decision"] == "block",
               "expected the analyzer-written problem to block the stop, got: #{inspect(context.response)}"

        reason = context.response["reason"]
        assert is_binary(reason)

        assert reason =~ @code_path,
               "expected the freshly-persisted problem to name the code file, got:\n#{reason}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end

defmodule CodeMySpecSpex.Story555.Criterion2428Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors.
  Criterion 2428 — a stop does not launch a subprocess analyzer; findings
  already persisted by an analysis run remain until a newer run lands.

  The fixture drives the same persisted-problem replacement path as an
  analyzer reconciliation. The hook is called without a command cassette,
  so a subprocess launched by the stop fails this specification.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A stop never runs a subprocess analyzer and recorded problems persist until a newer run lands",
    criterion: 2428 do
    scenario "the old finding survives a stop and only a newer reconciliation clears it" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "the compiler's latest persisted findings include a problem for the existing file",
             context do
        :ok =
          Fixtures.replace_problems(context.scope, context.component.id, "compiler", [
            %{message: "missing terminator: end", file_path: "lib/example_context.ex", line: 1}
          ])

        assert {:ok, before_stop} = compiler_problems(context.scope)
        assert before_stop =~ "lib/example_context.ex"
        {:ok, context}
      end

      when_ "the stop fires, then a clean run reconciles, then the stop fires again", context do
        first_stop =
          HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, after_first_stop} = compiler_problems(context.scope)

        :ok = Fixtures.replace_problems(context.scope, context.component.id, "compiler", [])

        second_stop =
          HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, after_second_stop} = compiler_problems(context.scope)

        {:ok,
         Map.merge(context, %{
           first_stop: first_stop,
           after_first_stop: after_first_stop,
           second_stop: second_stop,
           after_second_stop: after_second_stop
         })}
      end

      then_ "both stops are allowed and only the newer run clears the prior finding", context do
        assert context.first_stop == %{}
        assert context.after_first_stop =~ "lib/example_context.ex"
        assert context.second_stop == %{}
        refute context.after_second_stop =~ "lib/example_context.ex"
        {:ok, context}
      end
    end
  end

  defp compiler_problems(scope) do
    ToolLibrary.run("list_problems", %{"source" => "compiler"}, %{scope: scope})
  end
end

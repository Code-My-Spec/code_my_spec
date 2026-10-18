defmodule CodeMySpecSpex.Story1080.Criterion2172Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2172 — A problems offer is accepted when the agent writes: a
  tool call that writes files (write, edit, bash) after the offer accepts
  it; a read-only tool call alone does not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @broken_build Path.expand("test/fixtures/validation/pipeline_compile_error/compile.jsonl")

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Writing after a problems offer accepts it; reading alone does not", criterion: 2172 do
    scenario "a coder is refused a stop and then calls bash, writing a file" do
      given_ "a coder holding a task, mid-turn, that edited a file, is refused its stop",
             context do
        context = coder_holding_a_task(context)
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)

        HarnessHooks.write_file(
          context,
          "lib/example_context.ex",
          "defmodule ExampleContext do\n"
        )

        Fixtures.record_agent_edit(context.coder, "lib/example_context.ex")
        HarnessHooks.land_analysis(context, "compiler", @broken_build)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = HarnessHooks.end_turn(context, context.coder)

        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, "Fix these problems before stopping" <> _},
                       2_000

        {:ok, context}
      end

      when_ "a read-only tool call alone follows, then a write", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)

        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "c1", "list_tasks", %{})

        :ok = HarnessHooks.end_turn(context, context.coder)

        refused =
          context
          |> offers(context.coder, %{kind: "problems"})
          |> Enum.filter(&String.starts_with?(&1.subject, "problem_set:"))

        # The read-only turn ignored it, so the next rung stands open (2168).
        refute Enum.any?(refused, &(&1.status == "claimed")),
               "a read-only call alone accepted the problems offer:\n" <> listing(context)

        assert [%{id: open_id}] = Enum.filter(refused, &(&1.status == "open")), listing(context)

        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)

        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "c2", "write", %{
            "file_path" => "lib/example_context.ex",
            "content" => "defmodule ExampleContext do\nend\n"
          })

        :ok = HarnessHooks.end_turn(context, context.coder)
        {:ok, Map.put(context, :open_id, open_id)}
      end

      then_ "the problems offer is accepted and closed", context do
        open_id = context.open_id

        assert [%{status: "claimed"}] =
                 context
                 |> offers(context.coder, %{kind: "problems"})
                 |> Enum.filter(&(&1.id == open_id)),
               listing(context)

        {:ok, context}
      end
    end
  end
end

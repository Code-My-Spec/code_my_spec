defmodule CodeMySpecSpex.Story1080.Criterion1825Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1825 — A task-less pending tap-out is not a stall: the agent is
  held by the tap-out but is not reported stalled.

  `Digest.stalled?/1`'s guard requires `tapped_out?: false` — "deliberately
  not `tapped_out?`: that agent asked to stop and being left alone is the
  answer to its own request."
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A task-less tap-out is not reported as a stall", criterion: 1825 do
    scenario "product holds a blocked task and has tapped out of the whole agent" do
      given_ "a continuous product, its task blocked, that has asked to stop altogether",
             context do
        context = given_a_staffed_checkout(context, "spex_1825")
        context = FullSatisfactionFixtures.apply_without_three_amigos(context)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        context = Map.put(context, :product, product.id)
        context = asked_about_design(context)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.product}}

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "Nothing more I can design until answered"},
            tool_context(frame)
          )

        assert match?({:ok, _}, tapped), response_text(tapped)
        :ok = Fixtures.end_turn(context.scope, context.product, [])

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      given_ "an issue needing triage, claimable for product's role", context do
        filed =
          ToolLibrary.run(
            "create_issue",
            %{
              title: "Receipts print the wrong total",
              description: "Seen in QA",
              severity: "medium"
            },
            tool_context(%Frame{assigns: %{current_scope: context.scope}})
          )

        assert match?({:ok, _}, filed), response_text(filed)
        {:ok, context}
      end

      when_ "main's check-in interval passes", context do
        {:ok, check_in(context)}
      end

      then_ "product is held by the tap-out, but no stalled offer is recorded on it", context do
        assert offers(context, context.main_id, %{kind: "stalled"}) == [], listing(context)
        {:ok, context}
      end

      then_ "and main receives nothing naming product as stalled", context do
        main_id = context.main_id
        product = context.product

        receive do
          {:agent_dispatch, ^main_id, _ref, notice} ->
            refute notice =~ "Teammate stalled: the product agent #{product}", notice
        after
          500 -> :ok
        end

        {:ok, context}
      end
    end
  end

  # Product starts designing a story and asks the user about it, blocking that
  # task — the only task it holds.
  defp asked_about_design(context) do
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.product}}

    started =
      ToolLibrary.run(
        "start_task",
        %{
          requirement_name: "three_amigos_complete",
          entity_type: "story",
          entity_id: to_string(context.story.number)
        },
        tool_context(frame)
      )

    assert match?({:ok, _}, started), response_text(started)

    asked =
      ToolLibrary.run(
        "ask_question",
        %{
          task_id: extract_task_id!(started),
          questions: [
            %{
              question: "Who is the primary persona for refunds?",
              options: [%{label: "Shopper"}, %{label: "Clerk"}]
            }
          ]
        },
        tool_context(frame)
      )

    assert match?({:ok, _}, asked), response_text(asked)
    context
  end

  # Main's cadence timer fires once.
  defp check_in(context) do
    configured = ToolLibrary.run("cadence", %{seconds: 30}, tool_context(frame(context)))
    assert match?({:ok, _}, configured), response_text(configured)
    :ok = Fixtures.start_recovery_timer(context.scope)

    changed_at = DateTime.utc_now()
    response = ToolLibrary.run("cadence", %{seconds: 1}, tool_context(frame(context)))
    assert match?({:ok, _}, response), response_text(response)

    Fixtures.await_recovery_check(
      fn ->
        report = ToolLibrary.run("cadence", %{}, tool_context(frame(context)))
        response_text(report)
      end,
      changed_at
    )

    context
  end

  # A tool runs from a frame's assigns, with the scope under the key ToolLibrary reads.
  defp tool_context(%{assigns: assigns}), do: Map.put(assigns, :scope, assigns[:current_scope])
end

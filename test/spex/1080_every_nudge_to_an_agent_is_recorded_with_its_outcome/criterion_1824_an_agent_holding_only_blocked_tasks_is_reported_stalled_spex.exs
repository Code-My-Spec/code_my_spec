defmodule CodeMySpecSpex.Story1080.Criterion1824Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1824 — An agent idle beside claimable work for its role, holding
  only blocked tasks, is reported stalled.

  `list_agent_work` deliberately prints no computed status (criterion 3275:
  "a silence threshold that produces 'stalled' calls a streaming agent dead");
  the real mechanism is `Digest.stalled?/1` ("a blocked task is no work in
  hand: it holds only itself" — story 1080, in that module's own comment),
  reported to main as a `:stalled` offer via the cadence check-in, the same
  path criterion 1803 exercises.
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

  spex "A blocked-only agent beside claimable work is reported stalled", criterion: 1824 do
    scenario "product holds only a blocked task while an issue needs triage" do
      given_ "a continuous product whose only task is blocked, and a continuous main mid-turn",
             context do
        context = given_a_staffed_checkout(context, "spex_1824")
        context = FullSatisfactionFixtures.apply_without_three_amigos(context)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        context = Map.put(context, :product, product.id)
        context = asked_about_design(context)
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

        # Filing the issue pushes it to product at once (now idle-by-admission,
        # holding only its blocked task). That push lands off-process, so wait
        # for it to actually arrive before ageing it: a push landing after the
        # ageing call would stamp its own, still-recent turn_requested_at.
        product = context.product
        assert_receive {:work_turn_requested, ^product, _ref, _}, 2_000

        # The first push may be the one product's own turn end made; the issue's
        # re-offer comes off the graph recompute. Both stand before the ageing.
        :ok = Fixtures.settle_graph(context.scope)
        :ok = Fixtures.drain_background_work()

        # The push stands for five minutes before an untaken turn counts toward
        # a stall (`Offers.in_flight?/1`'s TTL), so ages past it here rather
        # than waiting on it for real.
        :ok = Fixtures.age_turn_request(context.scope, product, 301)
        {:ok, context}
      end

      when_ "main's check-in interval passes", context do
        {:ok, check_in(context)}
      end

      then_ "main is told product stalled, holding only its blocked task", context do
        main_id = context.main_id
        product = context.product
        assert_receive {:agent_dispatch, ^main_id, _ref, "Teammate stalled" <> _ = notice}, 5_000
        assert notice =~ product, notice
        {:ok, Map.put(context, :notice, notice)}
      end

      then_ "and it is recorded as an open stalled offer on that agent", context do
        assert [%{status: "open", subject: subject}] =
                 offers(context, context.main_id, %{kind: "stalled"}),
               listing(context)

        assert subject == "agent:#{context.product}"
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

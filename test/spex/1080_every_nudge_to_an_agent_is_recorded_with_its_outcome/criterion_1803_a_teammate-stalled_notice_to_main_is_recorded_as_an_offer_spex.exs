defmodule CodeMySpecSpex.Story1080.Criterion1803Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1803 — A teammate-stalled notice to main is recorded as an offer,
  claimed when main acts on it with any tool call before its turn ends.

  A stall is a continuous teammate whose role has work waiting that takes no
  turn — none running, and none on its way. Main's check-in sees it and tells main once; that notice is the offer.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [frame: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A stalled teammate is offered to main", criterion: 1803 do
    scenario "main's check-in finds a coder that is not taking its work" do
      given_ "coding work waiting, a continuous coder that takes no turn, and a continuous main mid-turn",
             context do
        context = coding_work_waiting(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.merge(context, %{coder: coder.id, main_id: main.id})}
      end

      when_ "main's check-in interval passes", context do
        {:ok, check_in(context)}
      end

      then_ "main is told the coder stalled", context do
        assert context.notice =~ "Teammate stalled: the coding agent #{context.coder}"
        {:ok, context}
      end

      then_ "and main holds an open stalled offer on that coder, linked to the notice",
            context do
        assert [offer] = offers(context, context.main_id, %{kind: "stalled"}), listing(context)
        assert offer.subject == "agent:#{context.coder}"
        assert offer.status == "open"
        assert offer.messages == [excerpt(context.notice)]
        {:ok, context}
      end
    end
  end

  spex "Main acting on the notice claims it", criterion: 1803 do
    scenario "main calls a tool after the notice and ends its turn" do
      given_ "main, mid-turn, was told a coder stalled", context do
        context = coding_work_waiting(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        context = check_in(Map.merge(context, %{coder: coder.id, main_id: main.id}))
        :ok = Fixtures.end_turn(context.scope, context.main_id)

        assert [%{status: "open"}] = offers(context, context.main_id, %{kind: "stalled"}),
               listing(context)

        :ok = Fixtures.deliver_agent_message(context.scope, context.main_id, context.notice_ref)
        {:ok, context}
      end

      when_ "main calls a tool and ends its turn", context do
        :ok =
          Fixtures.agent_tool_call(
            context.scope,
            %{id: context.main_id},
            "m1",
            "list_agent_work",
            %{}
          )

        :ok = Fixtures.end_turn(context.scope, context.main_id)
        {:ok, context}
      end

      then_ "the stalled offer is claimed", context do
        assert [%{status: "claimed"}] = offers(context, context.main_id, %{kind: "stalled"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  # The turn the coder was offered never started and is past its window: what
  # "takes no turn" means once a turn on its way is not a stall. Waited for, then
  # aged — while it stands no second turn is handed out, so the next one can only
  # come from the check-in's own recovery wake, after the digest has looked.
  defp never_starts(context) do
    coder = context.coder
    assert_receive {:work_turn_requested, ^coder, _ref, _prompt}, 5_000
    Fixtures.age_turn_request(context.scope, coder, 301)
  end

  # Main's cadence timer fires once. Main is mid-turn, so the stall arrives as
  # its own notice rather than inside a check-in turn.
  defp check_in(context) do
    {:reply, configured, _} = Cadence.execute(%{seconds: 30}, frame(context))
    refute configured.isError, response_text(configured)
    :ok = Fixtures.start_recovery_timer(context.scope)
    :ok = never_starts(context)

    changed_at = DateTime.utc_now()
    {:reply, response, _} = Cadence.execute(%{seconds: 1}, frame(context))
    refute response.isError, response_text(response)

    Fixtures.await_recovery_check(
      fn ->
        {:reply, report, _} = Cadence.execute(%{}, frame(context))
        response_text(report)
      end,
      changed_at
    )

    main_id = context.main_id
    assert_receive {:agent_dispatch, ^main_id, ref, "Teammate stalled" <> _ = notice}, 5_000
    Map.merge(context, %{notice: notice, notice_ref: ref})
  end
end

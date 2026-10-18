defmodule CodeMySpecSpex.Story1060.Criterion2120Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 2120 — A coding, QA or product agent's tap-out is offered to the
  main agent as work: main is woken with an offer naming the agent, its task
  and the reason, settles it with answer_notification, and an offer main
  ignores escalates rather than sitting.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Offers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp tapped_out_coder(context, path) do
    reply = join_working_copy(context, path, "the checkout")
    scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

    main = Fixtures.running_agent(scope, role: "main", working_copy: path)
    coder = Fixtures.running_agent(scope, role: "coding", working_copy: path)
    {coder, task} = Fixtures.agent_task_fixture(scope, coder, story_id: 1060)
    asking = %Frame{assigns: %{current_scope: scope, agent_id: coder.id}}

    tapped =
      ToolLibrary.run(
        "tap_out",
        %{
          task_id: task.id,
          reason: "the component this task would have built was already removed"
        },
        Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
      )

    assert match?({:ok, _}, tapped), inspect(tapped)
    [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

    %{scope: scope, main: main, coder: coder, task: task, permission_id: permission_id}
  end

  spex "The main agent is woken with an offer naming the agent, its task and the reason",
    criterion: 2120 do
    scenario "a coding agent with an active task taps out" do
      given_ "a coding agent with an active task", context do
        # given: already true — `tapped_out_coder/2` calls `TapOut.execute/2`.
        setup = tapped_out_coder(context, "/tmp/spex-2120a")
        {:ok, Map.merge(context, setup)}
      end

      when_ "its tap-out is raised", context do
        {:ok, context}
      end

      then_ "the main agent's own waiting work names the agent, its task and the reason",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        listing =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = response_text(listing)

        assert text =~ context.coder.id and text =~ context.task.id and
                 text =~ "already removed",
               """
               The main agent was woken with an offer, but what it is offered
               does not name the agent, its task and the reason — the main agent
               had to go looking for all three itself.

               listing:
               #{text}
               """

        {:ok, context}
      end
    end
  end

  spex "The main agent settles a tap-out it was woken for with answer_notification",
    criterion: 2120 do
    scenario "the main agent decides a coding agent's tap-out" do
      given_ "a coding agent's tap-out, raised while the main agent is running", context do
        # given: already true — `tapped_out_coder/2` calls `TapOut.execute/2`.
        setup = tapped_out_coder(context, "/tmp/spex-2120b")
        {:ok, Map.merge(context, setup)}
      end

      when_ "the main agent settles it with answer_notification", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        decided =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.permission_id,
              decision: "deny",
              answer: "the component this task would have built was already removed"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :decided, decided)}
      end

      then_ "it is settled, not left pending", context do
        assert match?({:ok, _}, context.decided),
               """
               The main agent could not settle a tap-out it was woken for with
               answer_notification.

               reply:
               #{response_text(context.decided)}
               """

        frame = %Frame{assigns: %{current_scope: context.scope}}

        listing =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        refute response_text(listing) =~ context.permission_id,
               """
               A tap-out the main agent already settled with answer_notification
               still shows up as its own waiting work.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end

  spex "An offer the main agent ignores escalates rather than sitting", criterion: 2120 do
    scenario "the main agent's turn ends without it acting on a tap-out it was woken for" do
      given_ "a coding agent's tap-out, offered to the main agent", context do
        # given: already true — `tapped_out_coder/2` calls `TapOut.execute/2`,
        # and `Offers.record/4` below records the resulting offer.
        setup = tapped_out_coder(context, "/tmp/spex-2120c")
        context = Map.merge(context, setup)

        # `request_turn_if_runnable/4` only records an offer once it actually
        # delivers a turn through a connected session -- unavailable here, so
        # this records the same offer directly, the way the ladder's own
        # ExUnit suite does (`every_kind_escalates_on_its_own_ladder_test.exs`).
        offer = Offers.record(nil, context.main, :denial, {"tap_out", context.permission_id})
        refute is_nil(offer), "the tap-out offer was not recorded"

        assert Offers.unreported_held_back(context.main.id) == [],
               "the offer was already held back before the main agent's turn ever ended"

        {:ok, context}
      end

      when_ "the main agent's turn ends having done nothing about it", context do
        # Settling at turn end is what the harness itself does after every
        # turn (`Offers.settle_turn/1`); there is no MCP tool for "a turn just
        # ended" to drive instead.
        assert :ok = Offers.settle_turn(context.main)
        {:ok, context}
      end

      then_ "the offer is held back and reported to the main agent again, rather than sitting silently ignored",
            context do
        assert [%{kind: :denial, subject_type: "tap_out"}] =
                 Offers.unreported_held_back(context.main.id),
               """
               A tap-out offer the main agent ignored stayed silently ignored
               instead of escalating to `held_back` for a stronger report.
               """

        {:ok, context}
      end
    end
  end
end

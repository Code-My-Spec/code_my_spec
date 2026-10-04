defmodule CodeMySpecSpex.Story1080.Criterion1675Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1675 — At turn end each open offer is settled by its kind.

  What counts as taking an offer depends on what was offered: work is taken
  by starting it, problems and the menu by doing anything about them, an
  answer by reading it or getting back to what it blocked. A notice that asks
  for nothing has no outcome to judge.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A work offer is claimed by starting its task", criterion: 1675 do
    scenario "the coder starts the work it was offered" do
      given_ "a coder offered work, mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, offered_work(context)}
      end

      when_ "it starts that work and ends its turn", context do
        context = start_agent_task(context, context.coder, next_task(context, context.coder))
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the work offer is claimed", context do
        assert [%{status: "claimed"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "A work offer is declined by a tap-out on it", criterion: 1675 do
    scenario "the coder starts the work and taps out of it" do
      given_ "a coder offered work, mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, offered_work(context)}
      end

      when_ "it starts the work, taps out of it and ends its turn", context do
        context = start_agent_task(context, context.coder, next_task(context, context.coder))

        {:reply, reply, _} =
          TapOut.execute(
            %{task_id: held_task_id(context, context.coder), reason: "Needs a product call."},
            agent_frame(context, context.coder)
          )

        refute reply.isError, response_text(reply)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the work offer is declined, with its reason", context do
        assert [offer] = offers(context, context.coder, %{kind: "work"}), listing(context)
        assert offer.status == "declined"
        assert offer.reason =~ "Needs a product call."
        {:ok, context}
      end
    end
  end

  spex "A work offer not taken is ignored", criterion: 1675 do
    scenario "the coder ends its turn without starting anything" do
      given_ "a coder offered work, mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, offered_work(context)}
      end

      when_ "it ends its turn", context do
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the work offer is ignored", context do
        assert [%{status: "ignored"} | _] =
                 context |> offers(context.coder, %{kind: "work"}) |> Enum.reverse(),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "The menu is claimed by any tool call after it", criterion: 1675 do
    scenario "a coder handed the menu acts on it" do
      given_ "a coder holding a task was handed the menu and has started its next turn",
             context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, handed_the_menu(context)}
      end

      when_ "it calls a tool and ends the turn", context do
        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "c1", "list_tasks", %{})

        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "that menu offer is claimed", context do
        assert first_of(context, "menu").status == "claimed", listing(context)
        {:ok, context}
      end
    end
  end

  spex "The menu with no tool call after it is ignored", criterion: 1675 do
    scenario "a coder handed the menu does nothing" do
      given_ "a coder holding a task was handed the menu and has started its next turn",
             context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, handed_the_menu(context)}
      end

      when_ "it ends the turn without calling a tool", context do
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "that menu offer is ignored", context do
        assert first_of(context, "menu").status == "ignored", listing(context)
        {:ok, context}
      end
    end
  end

  spex "An answer is claimed by any tool call after it", criterion: 1675 do
    scenario "an asker woken with its answer gets on with something" do
      given_ "an idle coder woken with the answer to its question, now mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, woken_with_answer(context)}
      end

      when_ "it calls a tool and ends the turn", context do
        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "c1", "list_tasks", %{})

        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the answer offer is claimed", context do
        assert [%{status: "claimed"}] = offers(context, context.coder, %{kind: "answer"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "An answer with no tool call after it is ignored", criterion: 1675 do
    scenario "an asker woken with its answer does nothing" do
      given_ "an idle coder woken with the answer to its question, now mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        {:ok, woken_with_answer(context)}
      end

      when_ "it ends the turn without calling a tool", context do
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the answer offer is ignored", context do
        assert [%{status: "ignored"}] = offers(context, context.coder, %{kind: "answer"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "Being unblocked is claimed by resuming the task", criterion: 1675 do
    scenario "a coder let back onto its task resumes it" do
      given_ "a coder whose blocking question was answered, now mid-turn", context do
        :ok = Fixtures.install_recording_agent_transport()
        context = coder_holding_a_task(context)
        question = ask(context, context.coder)
        :ok = user_answers(context, question, "Yes")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, context}
      end

      when_ "it resumes the task and ends the turn", context do
        context = start_agent_task(context, context.coder, context.task)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the unblocked offer is claimed", context do
        # The release and the graph change it causes may both offer the task;
        # the later supersedes the earlier, and the one that stands is claimed.
        standing =
          context
          |> offers(context.coder, %{kind: "unblocked"})
          |> Enum.reject(&(&1.status == "superseded"))

        assert [%{status: "claimed"}] = standing, listing(context)

        {:ok, context}
      end
    end
  end

  spex "A resume notice has no expectation", criterion: 1675 do
    scenario "a coder resumed after a restart ends its turn" do
      given_ "a coder told to resume its task after its harness came back, mid-turn",
             context do
        :ok = Fixtures.install_recording_agent_transport()

        context = coder_holding_a_task(context)
        :ok = report_agents_running(context, [context.coder])
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, context}
      end

      when_ "it ends the turn", context do
        :ok = HarnessHooks.end_turn(context, context.coder)
        {:ok, context}
      end

      then_ "the resume offer is settled as having no expectation", context do
        assert [%{status: "n_a"}] = offers(context, context.coder, %{kind: "resume"}),
               listing(context)

        {:ok, context}
      end
    end
  end

  spex "A check-in has no expectation", criterion: 1675 do
    scenario "main ends its check-in turn" do
      given_ "a continuous main was given its check-in", context do
        context = given_a_staffed_checkout(context, "spex_1675")
        context = FullSatisfactionFixtures.apply(context)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, _, _} = Cadence.execute(%{seconds: 30}, frame)
        :ok = Fixtures.start_recovery_timer(context.scope)
        changed_at = DateTime.utc_now()
        {:reply, _, _} = Cadence.execute(%{seconds: 1}, frame)

        Fixtures.await_recovery_check(
          fn ->
            {:reply, report, _} = Cadence.execute(%{}, frame)
            response_text(report)
          end,
          changed_at
        )

        HeldProvider.await_request(5_000)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.put(context, :main, main.id)}
      end

      when_ "the check-in turn ends", context do
        :ok = Fixtures.end_turn(context.scope, context.main)
        {:ok, context}
      end

      then_ "the check-in offer is settled as having no expectation", context do
        assert [%{status: "n_a"} | _] =
                 context |> offers(context.main, %{kind: "check_in"}) |> Enum.reverse(),
               listing(context)

        {:ok, context}
      end
    end
  end

  # A continuous coder that asked a question, was woken with the answer, and
  # has started that turn.
  defp woken_with_answer(context) do
    context = start_session(context)
    coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
    :ok = Fixtures.agent_said(context.scope, coder, "I need a decision first.")
    question = ask(context, coder.id)
    :ok = user_answers(context, question, "Yes")
    id = coder.id
    assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
    :ok = Fixtures.put_agent_mid_turn(context.scope, id)
    Map.put(context, :coder, id)
  end

  defp ask(context, agent_id) do
    params = %{
      questions: [
        %{"question" => "Ship it?", "options" => [%{"label" => "Yes"}, %{"label" => "No"}]}
      ]
    }

    {:reply, reply, _} = AskUserQuestion.execute(params, agent_frame(context, agent_id))
    refute reply.isError, response_text(reply)
    Fixtures.question_id_from(response_text(reply))
  end

  # The oldest offer of this kind: the one the turn under test settled.
  defp first_of(context, kind),
    do: context |> offers(context.coder, %{kind: kind}) |> List.last()
end

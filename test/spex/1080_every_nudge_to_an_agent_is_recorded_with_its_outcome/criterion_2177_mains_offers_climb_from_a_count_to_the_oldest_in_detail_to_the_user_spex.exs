defmodule CodeMySpecSpex.Story1080.Criterion2177Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2177 — Main's offers climb from a count, to the oldest in
  detail, to the user.

  Per product: not built as of this writing. `Offers.ladders()[{:work,
  "questions"}]` is `[:held_back]` today -- one rung, which simply stops
  re-offering rather than naming a count, showing the oldest in detail, or
  reaching the user. Written prescriptive against `Offers`' own public
  functions (never against the `@ladders` shape itself, which is expected to
  grow): asserts the three rungs' outcomes in order, and that the offer
  stays open afterward rather than closing. The user-held rung is asserted
  through the same path `escalate_question` already uses for a teammate's
  own question (`MainAgent.escalate_question/3`, surfaced to
  `list_notifications` with `holder: "user"`) -- not a new notification
  type.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
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

  defp asked(context, coder, text) do
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

    {:reply, asked, _} =
      AskUserQuestion.execute(
        %{questions: [%{"question" => text, "options" => [%{"label" => "Yes"}]}]},
        frame
      )

    refute asked.isError, response_text(asked)
    :ok = Fixtures.end_turn(context.scope, coder.id, [])
    asked
  end

  defp notifications_for_user(context) do
    {:reply, listing, _} = ListNotifications.execute(%{}, frame(context))
    refute listing.isError, response_text(listing)
    {:reply, scripted, _} = ListNotifications.script_result(%{}, frame(context))
    {response_text(listing), scripted}
  end

  spex "Main's own offer climbs to a count, to detail, to the user", criterion: 2177 do
    scenario "main ignores its questions offer through every rung, with two open behind it" do
      given_ "two teammates each asked an unanswered question, oldest first", context do
        context = given_a_staffed_checkout(context, "spex_2177")
        context = FullSatisfactionFixtures.apply(context)
        older = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        _oldest_ask = asked(context, older, "Which refund window?")
        newer = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        _newer_ask = asked(context, newer, "Which export format?")
        {:ok, Map.merge(context, %{older: older.id, newer: newer.id})}
      end

      given_ "a continuous main with no graph work of its own", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_to_work(context.scope)
        id = main.id
        assert_receive {:work_turn_requested, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.merge(context, %{main_id: id, first: first})}
      end

      then_ "the first rung reports a count of what is waiting", context do
        assert context.first =~ ~r/\b2\b.*question/i, context.first
        {:ok, context}
      end

      when_ "main ignores it and is offered the same questions again", context do
        id = context.main_id
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, second}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :second, second)}
      end

      then_ "the next rung shows the oldest one in detail", context do
        assert context.second =~ "Which refund window?", context.second
        refute context.second =~ "Which export format?", context.second
        {:ok, context}
      end

      when_ "main ignores that rung too, past the ladder's last step", context do
        id = context.main_id
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, context}
      end

      then_ "a notification held by the user is created, naming the offer", context do
        {text, rows} = notifications_for_user(context)
        assert text =~ "waiting on", text

        assert Enum.any?(rows, fn row ->
                 row["holder"] == "user" and
                   (row["agent_id"] == context.main_id or
                      Enum.any?(row["questions"] || [], &(&1 =~ "question")))
               end),
               "no user-held notification names main's held-back offer:\n#{inspect(rows)}"

        {:ok, context}
      end

      then_ "the offer stays open on main; it does not close by reaching the user", context do
        assert [%{status: "open"} | _] = offers(context, context.main_id, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end

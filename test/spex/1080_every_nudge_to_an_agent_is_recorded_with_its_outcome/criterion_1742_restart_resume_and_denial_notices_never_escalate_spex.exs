defmodule CodeMySpecSpex.Story1080.Criterion1742Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1742 — Restart, resume and denial notices never escalate; only work
  offers do.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An ignored denial does not escalate", criterion: 1742 do
    scenario "a coder ignores the notice that its tap-out was declined" do
      given_ "a coder offered work asked to leave the loop", context do
        context = offered_work(context)

        reply =
          ToolLibrary.run(
            "tap_out",
            %{reason: "Nothing for me here."},
            Map.put(
              agent_frame(context, context.coder).assigns,
              :scope,
              agent_frame(context, context.coder).assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, request_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(reply))
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, Map.put(context, :request, request_id)}
      end

      when_ "the request is denied, and the coder ends that turn doing nothing", context do
        reply =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.request,
              decision: "deny",
              answer: "There is work: take it."
            },
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), response_text(reply)
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, denial}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :denial, denial)}
      end

      then_ "the denial settles ignored with no next rung", context do
        assert context.denial =~ "declined", context.denial

        assert [%{status: "ignored"}] = offers(context, context.coder, %{kind: "denial"}),
               listing(context)

        {:ok, context}
      end

      then_ "and nothing it is told next escalates the denial", context do
        id = context.coder

        receive do
          # The work it was offered before tapping out may escalate on its own
          # ladder (criteria 1739–1741); the denial is not repeated or expanded.
          {:work_turn_requested, ^id, _ref, next} ->
            refute next =~ "declined", next
        after
          1_000 -> :ok
        end

        {:ok, context}
      end
    end
  end
end

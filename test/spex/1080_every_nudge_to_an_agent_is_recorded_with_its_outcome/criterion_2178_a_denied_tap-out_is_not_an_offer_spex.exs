defmodule CodeMySpecSpex.Story1080.Criterion2178Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2178 — A denied tap-out is not an offer: no denial offer is
  recorded, and the agent's open work offer, if any, is what asks it to
  act.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A denied tap-out records no denial offer", criterion: 2178 do
    scenario "a coder's tap-out on its open work offer is denied" do
      given_ "a coder offered work asked to leave the loop", context do
        context = offered_work(context)

        {:reply, reply, _} =
          TapOut.execute(%{reason: "Nothing for me here."}, agent_frame(context, context.coder))

        refute reply.isError, response_text(reply)
        [_, request_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(reply))
        {:ok, Map.put(context, :request, request_id)}
      end

      when_ "the request is denied", context do
        {:reply, reply, _} =
          AnswerNotification.execute(
            %{
              notification_id: context.request,
              decision: "deny",
              answer: "There is work: take it."
            },
            frame(context)
          )

        refute reply.isError, response_text(reply)
        {:ok, context}
      end

      then_ "no denial offer is recorded", context do
        assert offers(context, context.coder, %{kind: "denial"}) == [], listing(context)
        {:ok, context}
      end

      then_ "the agent's open work offer is what asks it to act", context do
        assert [%{status: "open"}] = offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end

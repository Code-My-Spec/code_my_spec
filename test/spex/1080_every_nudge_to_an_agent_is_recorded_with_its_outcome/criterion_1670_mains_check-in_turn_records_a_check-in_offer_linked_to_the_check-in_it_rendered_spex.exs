defmodule CodeMySpecSpex.Story1080.Criterion1670Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1670 — Main's check-in turn records a check-in offer linked to the
  check-in it rendered.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main's check-in is recorded as an offer", criterion: 1670 do
    scenario "the cadence interval passes for a continuous main" do
      given_ "a continuous main agent on a running timer", context do
        context = given_a_staffed_checkout(context, "spex_1670")
        context = FullSatisfactionFixtures.apply(context)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)

        # Something for the check-in to raise: an empty check never wakes main (1609).
        asker =
          Fixtures.running_agent(context.scope, role: "coding", working_copy: "/tmp/spex-1670")

        {:ok, _} =
          CodeMySpec.Notifications.create_agent_question_request(
            context.scope,
            asker.id,
            %{
              "title" => "Which way?",
              "questions" => [%{"question" => "Which way?", "options" => []}],
              "holder" => "main_agent"
            },
            nil
          )

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)

        {:reply, configured, _} = Cadence.execute(%{seconds: 30}, frame(context))
        refute configured.isError, response_text(configured)
        :ok = Fixtures.start_recovery_timer(context.scope)
        {:ok, Map.put(context, :main_id, main.id)}
      end

      when_ "the interval passes", context do
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

        HeldProvider.await_request(5_000)
        {:ok, context}
      end

      then_ "one check-in offer is recorded, linked to the check-in main was sent", context do
        assert [offer] = offers(context, context.main_id, %{kind: "check_in"}),
               "expected one check-in offer:\n" <> listing(context)

        assert offer.subject == "cadence"
        assert [message] = offer.messages
        assert message =~ "Check-in."

        [request] = HeldProvider.seen()

        assert Jason.decode!(request)["messages"] |> Jason.encode!() =~
                 String.slice(message, 0, 40),
               "the linked message is not the check-in main was sent"

        {:ok, context}
      end
    end
  end
end

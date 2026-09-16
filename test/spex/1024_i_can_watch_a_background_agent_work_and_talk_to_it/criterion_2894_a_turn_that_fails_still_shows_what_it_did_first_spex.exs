defmodule CodeMySpecSpex.Story1024.Criterion2894Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2894 — A turn that fails still shows what it did first.

  Rule: An agent's work appears as it happens, not only when the turn ends.

  The failure path that matters more than its happy path, and the one the
  obvious implementation gets wrong.

  Buffering a turn and writing it when it completes passes "I watch the work
  arrive" on any turn that succeeds, and loses everything on the turns you most
  wanted to watch. Streaming exists so you can see an agent going wrong early;
  if the record of what it did evaporates the moment it fails, you get the
  worst of both — no live view of the mistake, and no history of it either.

  ## Why a real refusal and not a reported one

  This drives a real turn against a provider this criterion makes refuse,
  because the shipped bug was on exactly that path and a pushed
  `turn_failed` event would have sailed straight past it.

  What QA found: the page does not wait for a turn, deliberately — the answer
  arrives as events — so when `send_message/4`'s turn came back `{:error, …}`
  there was nowhere for the error to go and it was dropped. The operator's
  message was recorded as delivered and the conversation went quiet, forever.
  Quiet is what an agent thinking looks like, which is the one thing a failure
  must never be indistinguishable from.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What already happened is not undone by what happens next" do
    scenario "A turn that fails still shows what it did first" do
      given_ "an agent that has already done something", context do
        copy = CodeMySpec.TempFile.dir("spex_2894")
        RealDisk.mkdir_p!(copy)

        agent = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_2894", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)

        conversation = Fixtures.agent_conversation(context.scope, agent)

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: conversation.id]}"
          )

        live
        |> form("form[phx-submit=send_message]", %{"message" => "write lib/half_done.ex"})
        |> render_submit()

        assert agent_received?(agent.id, "half_done"),
               "the premise is an agent that got as far as doing something; " <>
                 "without that there is nothing for a later failure to lose"

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:live, live)
         |> Map.put(:conversation, conversation)}
      end

      when_ "its next turn fails outright", context do
        HeldProvider.refuse()

        context.live
        |> form("form[phx-submit=send_message]", %{"message" => "now do the other thing"})
        |> render_submit()

        await_idle(context.agent.id)

        {:ok, context}
      end

      then_ "the work it did before failing is still there", context do
        {:ok, _reloaded, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: context.conversation.id]}"
          )

        assert html =~ "half_done",
               "the work the agent did before the turn failed is gone. That is the " <>
                 "buffered implementation: hold the turn, write it on success, lose " <>
                 "it on failure — which loses exactly the turns worth watching."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and the failure is shown rather than the work disappearing with it",
            context do
        # The provider's own words, not a generic "error". The page is full of
        # the word error — flash containers, form markup — and an assertion
        # matching those passes over a transcript that says nothing.
        #
        # Retried because the failure travels: engine to channel to database.
        # `await_idle/1` proves the agent has stopped deciding, which is a
        # weaker claim than "everything it said has landed".
        eventually(fn ->
          {:ok, _reloaded, html} =
            live(
              context.conn,
              ~p"/app/projects/#{context.project.id}/agent-conversation?#{[conversation: context.conversation.id]}"
            )

          assert html =~ "refused this request",
                 "the turn failed and the conversation does not say so, which leaves " <>
                   "an operator watching a transcript that simply stops — " <>
                   "indistinguishable from an agent still thinking. Got: " <>
                   String.slice(html, 0, 400)
        end)

        {:ok, context}
      end
    end
  end
end

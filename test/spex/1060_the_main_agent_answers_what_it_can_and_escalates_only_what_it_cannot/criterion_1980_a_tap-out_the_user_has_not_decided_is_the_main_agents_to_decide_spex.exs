defmodule CodeMySpecSpex.Story1060.Criterion1980Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1980 — A tap-out the user has not decided is the main agent's to
  decide.

  Rule: a tap-out nobody has decided becomes the main agent's to decide.

  A fresh tap-out waits on the user, same as `OpenQuestion.from_permission/3`
  says today. This criterion is about what happens once the project's own
  recovery interval has passed with nobody deciding it: the wait stops being
  the user's problem alone and becomes the main agent's too.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An aged, undecided tap-out is the main agent's own to settle", criterion: 1980 do
    scenario "nobody decides a coding agent's tap-out for a whole recovery interval" do
      given_ "a tapped-out agent nobody has decided for one recovery interval", context do
        reply = join_working_copy(context, "/tmp/spex-1980", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1980")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "this task's work should not exist — the component was already removed"},
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, tapped), inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        :ok = Fixtures.age_permission(scope, permission_id, Cadence.interval(scope) + 60)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:agent, agent)
         |> Map.put(:permission_id, permission_id)}
      end

      when_ "the main agent handles its waiting work", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, digest, _frame} = CheckIn.execute(%{}, frame)
        refute digest.isError, inspect(digest)

        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        {:reply, decided, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.permission_id,
              decision: "deny",
              answer:
                "the component this task would have built was already removed; nothing left to do"
            },
            frame
          )

        {:ok, context |> Map.put(:decided, decided) |> Map.put(:listing, listing)}
      end

      then_ "its own waiting work now names the tap-out as its own to decide", context do
        text = response_text(context.listing)

        assert text =~ ~r/needs your attention/i and text =~ context.permission_id,
               """
               After one recovery interval with nobody deciding it, the main agent's
               own waiting-work listing still does not say this tap-out is its own
               to decide.

               listing:
               #{text}
               """

        {:ok, context}
      end

      then_ "it approves or denies the tap-out, with its reason", context do
        refute context.decided.isError,
               """
               The main agent could not decide its own aged tap-out.

               reply:
               #{response_text(context.decided)}
               """

        {:ok, context}
      end

      then_ "and the coding agent is told the decision and the reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # The denial is delivered off `CodeMySpec.TaskSupervisor`
        # (`Notifications.wake_if_still_in_the_loop/2`), not written inline by
        # `AnswerNotification` -- a loaded machine can observe this read before
        # that task lands. `eventually/1` is the same wait every other
        # out-of-band-arrival criterion already uses for exactly this shape.
        eventually(fn ->
          {:reply, response, _frame} =
            ReadAgentConversation.execute(%{agent_id: context.agent.id}, frame)

          text = response_text(response)

          assert text =~ "declined" and text =~ "already removed",
                 """
                 The agent that tapped out was never told what the main agent decided, or why.

                 reply:
                 #{text}
                 """
        end)

        {:ok, context}
      end
    end
  end
end

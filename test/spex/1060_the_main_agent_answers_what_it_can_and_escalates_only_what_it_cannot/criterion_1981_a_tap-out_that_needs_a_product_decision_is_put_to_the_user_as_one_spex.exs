defmodule CodeMySpecSpex.Story1060.Criterion1981Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1981 — A tap-out that needs a product decision is put to the user
  as one.

  Rule: a tap-out nobody has decided becomes the main agent's to decide —
  unless deciding it would be deciding what the product does. 1980 is the
  main agent settling an aged tap-out itself; this is the same aging with the
  opposite outcome, because the reason itself says only the user can call it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A tap-out that would decide the product's behaviour goes up, not through main",
       criterion: 1981 do
    scenario "an aged tap-out says building the task would change what the product does" do
      given_ "an aged tap-out whose reason is a product decision", context do
        reply = join_working_copy(context, "/tmp/spex-1981", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1981")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, tapped, _frame} =
          TapOut.execute(
            %{
              reason:
                "building this task would change what the product does — it adds a feature " <>
                  "nobody asked for rather than fixing the bug the story describes"
            },
            asking
          )

        refute tapped.isError, inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        :ok = Fixtures.age_permission(scope, permission_id, Cadence.interval(scope) + 60)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:permission_id, permission_id)}
      end

      when_ "the main agent handles the aged tap-out", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, digest, _frame} = CheckIn.execute(%{}, frame)
        refute digest.isError, inspect(digest)

        {:reply, escalated, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.permission_id,
              reason: "only the user can say whether this feature should be built at all",
              as: "This task would add a feature nobody asked for instead of fixing the bug. Build it anyway?"
            },
            frame
          )

        {:ok, Map.put(context, :escalated, escalated)}
      end

      then_ "it does not decide it", context do
        refute context.escalated.isError,
               """
               The main agent could not send its own aged tap-out up to the user.

               reply:
               #{response_text(context.escalated)}
               """

        {:ok, context}
      end

      then_ "the user is shown what approving or denying changes, and it waits on them, not on main",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        text = response_text(listing)

        assert text =~ "Build it anyway?",
               """
               The tap-out reached the user without saying what approving or denying
               actually changes about their project.

               listing:
               #{text}
               """

        refute text =~ ~r/this is yours to decide/i,
               """
               The aged tap-out still reads as the main agent's to settle, instead of
               shown as waiting on the user.

               listing:
               #{text}
               """

        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story1053.Criterion1991Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 1991 — A tap-out left undecided is waiting on the main agent.

  Rule: a persisted question immediately reconsiders eligible main-agent work
  through normal turn admission, without a generic push message.

  An aged, undecided tap-out becomes the main agent's own to settle (1980, on
  story 1060). This criterion is about *how* that becomes visible: through the
  same admission gate every turn goes through — not a bypass that would force
  a turn on a main agent continuous-off keeps out of the loop.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.Agents.Main.Cadence
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

  spex "An aged tap-out is the main agent's own, through normal turn admission",
    criterion: 1991 do
    scenario "a continuous-off main agent is not given a bypass turn for it" do
      given_ "a coding agent's tap-out aged past one recovery interval, and a continuous-off main",
             context do
        context = given_a_staffed_checkout(context, "spex_1991")
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        coding = Fixtures.running_agent(context.scope, role: "coding", continuous: false)

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(main.id)

        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}

        {:reply, tapped, _} =
          TapOut.execute(
            %{reason: "this task's work should not exist — the component was already removed"},
            coding_frame
          )

        refute tapped.isError, response_text(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        :ok =
          Fixtures.age_permission(
            context.scope,
            permission_id,
            Cadence.interval(context.scope) + 60
          )

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           coding_id: coding.id,
           permission_id: permission_id,
           running_ids: Machine.running()
         })}
      end

      when_ "the main agent looks at what is waiting", context do
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.main_frame)
        refute inbox.isError, response_text(inbox)
        {:ok, Map.put(context, :listing, response_text(inbox))}
      end

      then_ "the aged tap-out is listed with the agent and task it came from", context do
        assert context.listing =~ context.permission_id and
                 context.listing =~ context.coding_id,
               """
               The aged tap-out is not listed as the main agent's own, naming the
               agent and task it came from.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end

      then_ "a continuous-off main is not given a bypass turn for it", context do
        assert Machine.running() == context.running_ids
        assert {:ok, %{busy?: false}} = Machine.status(context.main_id)

        assert HeldProvider.seen() == [],
               "a continuous-off main agent was given a turn it never asked for"

        {:ok, context}
      end
    end
  end
end

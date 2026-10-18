defmodule CodeMySpecSpex.Story1060.Criterion1982Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1982 — A tap-out decided in time never reaches the main agent.

  Rule: a tap-out nobody has decided becomes the main agent's to decide.
  1980 and 1981 are both about what happens once the recovery interval has
  passed. This is the floor underneath both of them: the ordinary case, where
  the user simply answers before the interval is up, is not main's problem at
  all — not a lesser version of it, none of it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The user deciding promptly settles it before main is ever involved", criterion: 1982 do
    scenario "the user approves a tap-out well within the recovery interval" do
      given_ "a coding agent's fresh tap-out", context do
        reply = join_working_copy(context, "/tmp/spex-1982", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-1982")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{reason: "this task's work should not exist"},
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, tapped), inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:permission_id, permission_id)}
      end

      when_ "the user decides it within one recovery interval", context do
        {:ok, view, _html} = live(context.conn, "/app/permissions/#{context.permission_id}")
        view |> render_click("approve", %{"id" => context.permission_id})

        {:ok, context}
      end

      then_ "the main agent is given no turn for it, and it is not listed as waiting on main",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListNotifications.execute(%{}, frame)

        refute response_text(listing) =~ context.permission_id,
               """
               A tap-out the user already decided still shows up as something for
               the main agent to look at. It was settled before main had any
               reason to be involved — not involved a little, not involved.

               listing:
               #{response_text(listing)}
               """

        {:ok, context}
      end
    end
  end
end

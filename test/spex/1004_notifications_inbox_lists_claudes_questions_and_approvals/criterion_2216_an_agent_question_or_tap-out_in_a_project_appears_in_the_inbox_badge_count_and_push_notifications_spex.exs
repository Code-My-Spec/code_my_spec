defmodule CodeMySpecSpex.Story1004.Criterion2216Spex do
  @moduledoc """
  Story 1004, criterion 2216: an agent's question or tap-out belongs to the
  account that owns its project, not to whichever user happens to be logged
  in when it was stamped — so every owner and admin of that account is a
  recipient, not just one of them.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent's requests reach every owner and admin of its account", criterion: 2216 do
    scenario "An owner and an admin both see an agent's question and tap-out" do
      given_ "an account with an owner and an admin, and an agent in its project", context do
        admin = Fixtures.user_fixture()
        Fixtures.member_fixture(admin, context.account, :admin)
        agent = Fixtures.running_agent(context.scope)

        question = Fixtures.ask_question(context.scope.user.id, agent_id: agent.id)
        tap_out = Fixtures.request_permission(context.scope.user.id, agent_id: agent.id)

        {:ok,
         Map.merge(context, %{
           admin: admin,
           request_ids: [question, tap_out]
         })}
      end

      when_ "the owner and the admin each open the notifications inbox", context do
        {:ok, owner_view, _} = live(context.conn, "/app/notifications")

        {:ok, admin_view, _} =
          live(log_in_user(Phoenix.ConnTest.build_conn(), context.admin), "/app/notifications")

        {:ok, Map.merge(context, %{owner_view: owner_view, admin_view: admin_view})}
      end

      then_ "both see the question and the tap-out, and a pending count of two", context do
        for view <- [context.owner_view, context.admin_view], id <- context.request_ids do
          assert has_element?(view, "[data-test='notification'][data-id='#{id}']")
        end

        assert has_element?(
                 context.owner_view,
                 "[data-test='notification-badge'][data-count='2']"
               )

        assert has_element?(
                 context.admin_view,
                 "[data-test='notification-badge'][data-count='2']"
               )

        assert Fixtures.count_pending_notifications(context.scope.user.id) == 2
        assert Fixtures.count_pending_notifications(context.admin.id) == 2
        {:ok, context}
      end
    end
  end
end

defmodule CodeMySpecSpex.Story1004.Criterion2217Spex do
  @moduledoc """
  Story 1004, criterion 2217: plain members and users outside the project's
  owning account cannot see its agent requests. Owners remain a positive
  visibility control. Agentless session requests retain stamped-user routing.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpec.AccountsFixtures
  alias CodeMySpec.Notifications

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent requests exclude plain members and outsiders", criterion: 2217 do
    scenario "Account membership limits visibility despite the stamped user" do
      given_ "a project's agent has requests stamped with a plain member", context do
        member = Fixtures.user_fixture()
        outsider = Fixtures.user_fixture()
        AccountsFixtures.member_fixture(member, context.account, :member)
        AccountsFixtures.account_with_owner_fixture(outsider)
        agent = Fixtures.running_agent(context.scope)

        question =
          Fixtures.ask_question(member.id, agent_id: agent.id, title: "Private project question")

        permission = Fixtures.request_permission(member.id, agent_id: agent.id)

        {:ok,
         Map.merge(context, %{
           member: member,
           outsider: outsider,
           request_ids: [question, permission]
         })}
      end

      when_ "the owner, member and outsider open their inboxes", context do
        {:ok, owner_view, _} = live(context.conn, "/app/notifications")

        {:ok, member_view, _} =
          live(log_in_user(Phoenix.ConnTest.build_conn(), context.member), "/app/notifications")

        {:ok, outsider_view, _} =
          live(log_in_user(Phoenix.ConnTest.build_conn(), context.outsider), "/app/notifications")

        {:ok,
         Map.merge(context, %{
           owner_view: owner_view,
           member_view: member_view,
           outsider_view: outsider_view
         })}
      end

      then_ "the owner sees both requests and a count of two", context do
        for id <- context.request_ids do
          assert has_element?(context.owner_view, "[data-test='notification'][data-id='#{id}']")
        end

        assert Notifications.count_pending_notifications(context.scope.user.id) == 2
        {:ok, context}
      end

      then_ "neither excluded user sees either request or a pending count", context do
        for view <- [context.member_view, context.outsider_view], id <- context.request_ids do
          refute has_element?(view, "[data-test='notification'][data-id='#{id}']")
        end

        assert Notifications.count_pending_notifications(context.member.id) == 0
        assert Notifications.count_pending_notifications(context.outsider.id) == 0
        {:ok, context}
      end
    end
  end
end

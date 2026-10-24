defmodule CodeMySpecSpex.Story1004.Criterion2218Spex do
  @moduledoc """
  Story 1004, criterion 2218: a request shared by every owner and admin of an
  account resolves for all of them at once, and names which one of them
  answered it — not whichever of them happened to be looking.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Any recipient's answer resolves the request for every recipient", criterion: 2218 do
    scenario "The admin answers and the owner sees it resolved by the admin" do
      given_ "an owner and an admin both have a pending agent question", context do
        admin = Fixtures.user_fixture()
        Fixtures.member_fixture(admin, context.account, :admin)
        agent = Fixtures.running_agent(context.scope)

        question_id = Fixtures.ask_question(context.scope.user.id, agent_id: agent.id)

        {:ok, Map.merge(context, %{admin: admin, question_id: question_id})}
      end

      when_ "the admin, not the owner, answers it", context do
        admin_conn = log_in_user(Phoenix.ConnTest.build_conn(), context.admin)
        {:ok, answer_view, _html} = live(admin_conn, "/app/questions/#{context.question_id}")

        answer_view
        |> form("main form", %{"q_0" => "A"})
        |> render_submit()

        {:ok, context}
      end

      then_ "it leaves both the owner's and the admin's pending list", context do
        assert Fixtures.count_pending_notifications(context.scope.user.id) == 0
        assert Fixtures.count_pending_notifications(context.admin.id) == 0
        {:ok, context}
      end

      then_ "both see it in their history, answered by the admin", context do
        {:ok, owner_view, _} = live(context.conn, "/app/notifications")

        {:ok, admin_view, _} =
          live(log_in_user(Phoenix.ConnTest.build_conn(), context.admin), "/app/notifications")

        for view <- [owner_view, admin_view] do
          assert has_element?(
                   view,
                   "[data-test='notification'][data-id='#{context.question_id}'][data-status='answered']"
                 )

          assert has_element?(
                   view,
                   "[data-test='notification'][data-id='#{context.question_id}'] [data-test='notification-answerer']",
                   "Answered by #{context.admin.email}"
                 )
        end

        {:ok, context}
      end
    end
  end
end

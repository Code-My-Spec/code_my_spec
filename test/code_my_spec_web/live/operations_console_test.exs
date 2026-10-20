defmodule CodeMySpecWeb.OperationsConsoleTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_project]

  test "chats, mail, users and content share the Operations sidebar", %{
    conn: conn,
    project: project
  } do
    for {path, key} <- [inbox: :chats, mail: :mail, users: :users, content: :content] do
      {:ok, view, _html} = live(conn, "/app/projects/#{project.id}/#{path}")

      assert has_element?(view, "[data-test='operations-sidebar']"), "#{path} is not framed"
      assert has_element?(view, "[data-test='operations-nav-#{key}'].menu-active")
    end
  end
end

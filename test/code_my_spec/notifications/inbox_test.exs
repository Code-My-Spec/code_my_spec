defmodule CodeMySpec.Notifications.InboxTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Notifications

  import CodeMySpec.UsersFixtures

  setup do
    scope = user_scope_fixture()
    %{user_id: scope.user.id}
  end

  defp question!(user_id, text \\ "Which database?") do
    {:ok, req} =
      Notifications.create_question_request(user_id, %{
        "questions" => [%{"question" => text, "options" => []}]
      })

    req
  end

  defp permission!(user_id) do
    {:ok, req} =
      Notifications.create_permission_request(user_id, %{
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "mix test"}
      })

    req
  end

  describe "list_notifications/1" do
    test "returns both request types, pending before resolved", %{user_id: user_id} do
      answered = question!(user_id, "old?")
      {:ok, _} = Notifications.answer_question_request(answered.id, %{"old?" => "yes"})
      pending_q = question!(user_id, "new?")
      pending_p = permission!(user_id)

      items = Notifications.list_notifications(user_id)

      assert Enum.map(items, & &1.id) |> Enum.sort() ==
               Enum.sort([answered.id, pending_q.id, pending_p.id])

      {pending, resolved} = Enum.split_with(items, &(&1.status == "pending"))
      assert Enum.map(pending, & &1.id) |> Enum.sort() == Enum.sort([pending_q.id, pending_p.id])
      assert [%{id: resolved_id}] = resolved
      assert resolved_id == answered.id
    end

    test "excludes other users' requests", %{user_id: user_id} do
      other = user_scope_fixture()
      question!(other.user.id, "not yours")
      mine = question!(user_id)

      assert [%{id: id}] = Notifications.list_notifications(user_id)
      assert id == mine.id
    end
  end

  describe "list_resolved_notifications/2" do
    test "returns the most recent resolved items across both types, truncated consistently", %{
      user_id: user_id
    } do
      q1 = question!(user_id, "q1")
      {:ok, _} = Notifications.answer_question_request(q1.id, %{"q1" => "a"})
      p1 = permission!(user_id)
      {:ok, _} = Notifications.resolve_permission_request(p1.id, "allow")
      q2 = question!(user_id, "q2")
      {:ok, _} = Notifications.answer_question_request(q2.id, %{"q2" => "a"})

      # Never counted: still pending.
      still_open = question!(user_id, "still open")

      full = Notifications.list_resolved_notifications(user_id, limit: 10)
      full_ids = Enum.map(full, & &1.id)

      assert Enum.sort(full_ids) == Enum.sort([q1.id, p1.id, q2.id])
      refute still_open.id in full_ids

      # inserted_at is second-precision, so these three routinely tie on
      # timestamp within one test — the ordering itself only needs to be
      # deterministic (see `newest_first/2`), and a smaller limit must agree
      # with the head of the unlimited list rather than picking differently.
      page = Notifications.list_resolved_notifications(user_id, limit: 2)
      assert Enum.map(page, & &1.id) == Enum.take(full_ids, 2)
    end

    test "excludes other users' requests", %{user_id: user_id} do
      other = user_scope_fixture()
      other_q = question!(other.user.id, "not yours")
      {:ok, _} = Notifications.answer_question_request(other_q.id, %{"not yours" => "a"})

      mine = question!(user_id)
      {:ok, _} = Notifications.answer_question_request(mine.id, %{"Which database?" => "pg"})

      assert [%{id: id}] = Notifications.list_resolved_notifications(user_id)
      assert id == mine.id
    end

    test "the :before cursor pages by exact id even when timestamps tie", %{user_id: user_id} do
      # inserted_at is second-precision, so requests created in the same test
      # (same second, no sleeps — feedback_no_sleeps_in_tests) land on an
      # identical timestamp. Paging on inserted_at alone would drop or repeat
      # whichever of these ties fell on the split.
      ids =
        for i <- 1..5 do
          req = question!(user_id, "q#{i}")
          {:ok, _} = Notifications.answer_question_request(req.id, %{"q#{i}" => "a"})
          req.id
        end

      page1 = Notifications.list_resolved_notifications(user_id, limit: 2)
      assert length(page1) == 2

      oldest = List.last(page1)
      seen_ids = for %{id: id, inserted_at: at} <- page1, at == oldest.inserted_at, do: id

      page2 =
        Notifications.list_resolved_notifications(user_id,
          limit: 2,
          before: {oldest.inserted_at, seen_ids}
        )

      page1_ids = Enum.map(page1, & &1.id)
      page2_ids = Enum.map(page2, & &1.id)

      assert page1_ids -- page2_ids == page1_ids, "page 2 repeated a row from page 1"
      assert Enum.all?(page1_ids ++ page2_ids, &(&1 in ids))
      assert length(Enum.uniq(page1_ids ++ page2_ids)) == 4
    end
  end

  describe "count_pending_notifications/1" do
    test "counts pending across both types, ignoring resolved", %{user_id: user_id} do
      question!(user_id)
      permission!(user_id)
      answered = question!(user_id, "done?")
      {:ok, _} = Notifications.answer_question_request(answered.id, %{"done?" => "yep"})

      assert Notifications.count_pending_notifications(user_id) == 2
    end
  end

  describe "notification broadcasts" do
    test "create and answer broadcast on both topics", %{user_id: user_id} do
      Notifications.subscribe_notifications(user_id)
      Notifications.subscribe_notifications_list(user_id)

      req = question!(user_id)
      assert_receive {:pending_notifications_changed}
      assert_receive {:notifications_changed}

      {:ok, _} = Notifications.answer_question_request(req.id, %{"Which database?" => "pg"})
      assert_receive {:pending_notifications_changed}
      assert_receive {:notifications_changed}
    end

    test "permission create and resolve broadcast", %{user_id: user_id} do
      Notifications.subscribe_notifications(user_id)

      req = permission!(user_id)
      assert_receive {:pending_notifications_changed}

      {:ok, _} = Notifications.resolve_permission_request(req.id, "allow")
      assert_receive {:pending_notifications_changed}
    end
  end
end

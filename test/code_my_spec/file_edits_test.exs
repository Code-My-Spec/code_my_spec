defmodule CodeMySpec.FileEditsTest do
  @moduledoc """
  `consume_edits/2` and `consume_edits_by_agent/3` — d726cfda.

  Reading the ledger was never the bug; never forgetting what had been read
  was. These delete exactly the rows a caller has already acted on, scoped to
  the paths it read rather than to the whole session, so a write that lands
  between the read and the consume is never lost.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.FileEdits

  @session "consume-edits-session"

  describe "consume_edits/2" do
    test "removes exactly the paths named, leaving the rest of the session's ledger" do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")
      :ok = FileEdits.track_edit(@session, "lib/theirs.ex")

      :ok = FileEdits.consume_edits(@session, ["lib/mine.ex"])

      assert FileEdits.get_edited_files(@session) == ["lib/theirs.ex"]
    end

    test "a session with nothing new after consuming reads as quiet", %{} do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")

      assert FileEdits.get_edited_files(@session) == ["lib/mine.ex"]

      :ok = FileEdits.consume_edits(@session, ["lib/mine.ex"])

      assert FileEdits.get_edited_files(@session) == [],
             "an empty ledger after consuming is the whole fix — a session that wrote " <>
               "nothing new must read as having wrote nothing new"
    end

    test "does not touch another session's rows for the same path" do
      other = "other-#{@session}"
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")
      :ok = FileEdits.track_edit(other, "lib/mine.ex")

      :ok = FileEdits.consume_edits(@session, ["lib/mine.ex"])

      assert FileEdits.get_edited_files(other) == ["lib/mine.ex"]
    end

    test "an empty path list is a no-op, not a delete-everything" do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")

      :ok = FileEdits.consume_edits(@session, [])

      assert FileEdits.get_edited_files(@session) == ["lib/mine.ex"]
    end

    test "a path written after the read it is consuming survives" do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")
      read_at_this_point = FileEdits.get_edited_files(@session)

      # Simulates a write landing between the read and the consume call —
      # the exact race the path-scoped delete (rather than a blanket
      # session-wide delete) exists to avoid.
      :ok = FileEdits.track_edit(@session, "lib/late.ex")

      :ok = FileEdits.consume_edits(@session, read_at_this_point)

      assert FileEdits.get_edited_files(@session) == ["lib/late.ex"]
    end
  end

  describe "consume_edits_by_agent/3" do
    test "removes this agent's path, leaving another path this session recorded" do
      agent = "agent-#{System.unique_integer([:positive])}"
      :ok = FileEdits.track_edit(@session, "lib/mine.ex", agent)
      :ok = FileEdits.track_edit(@session, "lib/theirs.ex")

      :ok = FileEdits.consume_edits_by_agent(@session, agent, ["lib/mine.ex"])

      assert FileEdits.get_edited_files_by_agent(@session, agent) == []
      assert FileEdits.get_edited_files(@session) == ["lib/theirs.ex"]
    end

    test "does not remove the same path recorded for a different agent" do
      agent = "agent-#{System.unique_integer([:positive])}"
      other_agent = "agent-#{System.unique_integer([:positive])}"
      other_session = "other-#{@session}"
      :ok = FileEdits.track_edit(@session, "lib/mine.ex", agent)
      :ok = FileEdits.track_edit(other_session, "lib/mine.ex", other_agent)

      :ok = FileEdits.consume_edits_by_agent(@session, agent, ["lib/mine.ex"])

      assert FileEdits.get_edited_files_by_agent(other_session, other_agent) == [
               "lib/mine.ex"
             ]
    end

    test "an empty path list is a no-op" do
      agent = "agent-#{System.unique_integer([:positive])}"
      :ok = FileEdits.track_edit(@session, "lib/mine.ex", agent)

      :ok = FileEdits.consume_edits_by_agent(@session, agent, [])

      assert FileEdits.get_edited_files_by_agent(@session, agent) == ["lib/mine.ex"]
    end
  end
end

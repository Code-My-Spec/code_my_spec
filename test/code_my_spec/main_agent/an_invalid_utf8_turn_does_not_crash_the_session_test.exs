defmodule CodeMySpec.Agents.Main.AnInvalidUtf8TurnDoesNotCrashTheSessionTest do
  @moduledoc """
  Issue `5df56711`, criteria 1250, 1251 and 1259 (story 1055).

  `Anubis.Server.Session.decode_task_result/3` JSON-encodes a tool's reply
  with Elixir's strict encoder, which raises on invalid UTF-8 and kills the
  whole MCP session rather than returning an error. A single bad byte
  somewhere in a recorded turn — a faithfully-recorded crash carrying raw
  terms, say — must not reach that encoder un-scrubbed, and scrubbing must
  not drop the turn: criterion 1251 promises the exact error text, not a
  paraphrase, and an elided turn is a paraphrase of nothing at all.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main, as: MainAgent

  test "a turn with invalid UTF-8 renders as valid, JSON-encodable text" do
    bad = <<"the crash was: ", 0xFF, 0xFE, " (unexpected_utf8)">>

    refute String.valid?(bad),
           "the fixture itself has to be invalid UTF-8 for this to mean anything"

    turn = %{agent_id: "a1", role: :assistant, text: bad, tool_calls: nil}

    rendered = MainAgent.turn_line(turn)

    assert String.valid?(rendered),
           "turn_line/1 produced invalid UTF-8 rather than scrubbing it"

    assert {:ok, _} = Jason.encode(rendered),
           "the rendered turn still cannot be JSON-encoded"
  end

  test "the readable content survives scrubbing — it is not dropped" do
    bad = <<"the crash was: ", 0xFF, 0xFE, " (unexpected_utf8)">>
    turn = %{agent_id: "a1", role: :assistant, text: bad, tool_calls: nil}

    rendered = MainAgent.turn_line(turn)

    assert rendered =~ "the crash was:" and rendered =~ "unexpected_utf8",
           """
           Scrubbing dropped the readable content instead of replacing only the
           invalid bytes — criterion 1251 needs the exact error text, not an
           elided turn.

           Got: #{inspect(rendered)}
           """
  end

  test "a tool-result turn's text is scrubbed too" do
    bad = <<"result: ", 0xFF, " done">>
    turn = %{agent_id: "a1", tool_call_id: "call_1", tool_failed: true, text: bad}

    rendered = MainAgent.turn_line(turn)

    assert String.valid?(rendered)
    assert {:ok, _} = Jason.encode(rendered)
  end
end

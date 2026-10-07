defmodule CodeMySpec.CodeMode.ANameFromAnotherRoleSaysSoTest do
  @moduledoc """
  A tool this role does not carry is named as such, not as a misspelling.

  Issue `27fb2de3`, from the stop hook on story 1015. A QA agent was refused and
  told to "block it with `ask_user_question` or `tap_out`", so it tried both from
  a script. `tap_out` is excluded from scripts *and* withheld from the QA role
  (`ToolSets`), and what it got back was:

      No tool is bound under that name â it may be a similar name, or on this
      project's machine.

  Every clause of that is wrong for `tap_out`. It is not a similar name, it is
  not on the machine, and the one place it is real â another role's tool list â
  is the one place the sentence does not look. An agent reading it goes looking
  for spellings and for its machine, which is what the issue says it did.

  `tool_docs` learned to answer this exact question for this exact tool
  (`e809c0db`). This is the same answer from the refusal the agent actually
  hits, and the two have to agree or the pair reads as a contradiction.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  defp catalog do
    Catalog.from(
      [%{name: "list_stories", description: "List stories"}],
      fn _tool -> fn _args -> {:ok, "ok"} end end,
      nil
    )
  end

  # The QA case: a grant that does not include `tap_out`, and a server whose
  # registrations include it. Both lists are what `run_script` passes.
  defp run_as_qa(script) do
    CodeMode.eval(catalog(), script,
      out_of_scope: [],
      agent_kind: :qa,
      carried: ["list_stories"],
      direct_names: ["tap_out", "ask_user_question", "create_issue"]
    )
  end

  test "another role's tool is named as another role's tool" do
    result = run_as_qa(~s|return tap_out({ reason = "stuck" })|)

    assert result.error.message =~ "tap_out"
    assert result.error.message =~ ~r/another role|belongs to/i,
           "the agent must hear that the tool is real and not its to call, or it " <>
             "keeps guessing names"
  end

  test "and is not offered the machine or a near miss" do
    result = run_as_qa(~s|return tap_out({ reason = "stuck" })|)

    refute result.error.message =~ "machine",
           "sending a QA agent to the browser for tap_out is a search with no answer"

    refute result.error.message =~ "similar name"
  end

  # `tap_out` is also excluded from scripts, so it is the one name that has two
  # true sentences. Both belong in the answer: the caller cannot script it *and*
  # cannot call it directly.
  test "an excluded tool the role carries still says to call it directly" do
    result =
      CodeMode.eval(catalog(), ~s|return tap_out({})|,
        out_of_scope: [],
        agent_kind: :main,
        carried: Catalog.excluded(),
        direct_names: []
      )

    assert result.error.message =~ "Call it directly as a tool"
  end

  # A person, or an agent started before scoping existed: nothing is out of
  # scope, so there is nothing to explain and `:all` keeps every name as it was.
  test "an unscoped caller is left alone" do
    result = CodeMode.eval(catalog(), ~s|return page_wait_for_timeout({})|, [])

    assert result.error.message =~ "No tool is bound under that name"
  end
end

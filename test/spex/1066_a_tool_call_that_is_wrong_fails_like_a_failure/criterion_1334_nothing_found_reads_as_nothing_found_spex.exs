defmodule CodeMySpecSpex.Story1066.Criterion3386Spex do
  @moduledoc """
  Story 1066 -- A tool call that is wrong fails like a failure
  Criterion 3386 -- Nothing found reads as nothing found.

  The rule:

  > A call that was malformed and a call that found nothing never look the same.

  ## The half that must keep working

  This is the control. Criterion 3387 asserts that a rejected call cannot be
  mistaken for an empty answer; this one asserts the other side -- that an
  empty answer is still a perfectly good answer and does not start looking
  like a failure once failures get louder.

  Worth writing because the obvious fix for 3387 is to make everything shout.
  A sandbox that treats "no rules on this story" as an error has moved the
  problem rather than solved it: an agent would learn to ignore the shouting,
  which is where this started.

  ## Rewritten by product decision (253b3b93)

  253b3b93 made list_rules return a real Lua table through run_script,
  where it previously returned rendered prose. The second scenario below
  used to assert emptiness as a text proxy (one of "(0)"/"none"/"empty"/
  "no rules" appearing in the rendered text) because prose was all a
  script could ever get back. That proxy no longer holds once the answer
  is data, so product decided it alone could be rewritten to assert
  directly on the shape the script received (a table, zero rows) instead
  of words in a string -- the first then_ (a call that found nothing is
  not an error) is unchanged; it was never the proxy.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Nothing found reads as nothing found", criterion: 1334 do
    scenario "a script calls a tool that legitimately finds nothing" do
      given_ "a story with no rules on it", context do
        story =
          CodeMySpecSpex.Fixtures.authored_story(context.scope, "A story nobody has ruled on")

        {:ok, Map.put(context, :story, story)}
      end

      when_ "a script asks for its rules", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        script =
          "local r = list_rules({ story_number = #{context.story.number} }); " <>
            "return { kind = type(r), count = #r }"

        {:reply, response, _frame} = RunScript.execute(%{script: script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "the agent can tell the call worked", context do
        refute context.response.isError,
               "asking for the rules of a story that has none came back as a failure. " <>
                 "Nothing went wrong -- the answer is that there are no rules -- and an " <>
                 "agent taught to treat this as an error learns to ignore errors. " <>
                 "Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and that the answer was empty", context do
        kind_and_count = Jason.decode!(context.text |> String.trim_leading("Returned:\n"))

        assert kind_and_count["kind"] == "table" and kind_and_count["count"] == 0,
               "the call worked, but the agent cannot tell an empty list from a " <>
                 "truncated or failed one unless the script actually received a real, " <>
                 "empty table -- not a string, not nil. Got:\n" <>
                 String.slice(context.text, 0, 300)

        {:ok, context}
      end
    end
  end
end

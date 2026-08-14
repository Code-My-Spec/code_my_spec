defmodule CodeMySpecSpex.Story984.Criterion2368Spex do
  @moduledoc """
  Story 984 — Watch what a background sprite is actually doing.
  Criterion 2368 — A file-sized payload is cut, and says so.

  An agent writing a source file sends its whole contents as an argument. Held
  in the transcript in full, one call buries every turn around it — and the
  operator scrolling past it cannot tell whether they are still in the same
  call.

  Cutting silently would be worse than not cutting. A transcript that looks
  complete and is not is a record you cannot trust, so the cut announces
  itself.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A whole file in an argument does not bury the transcript" do
    scenario "A file-sized payload is cut, and says so" do
      when_ "the agent writes a file of several thousand characters", context do
        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("write the module"),
          Fixtures.model_response([
            Fixtures.tool_block("Write", %{
              "file_path" => "lib/big.ex",
              "content" => String.duplicate("# a line of a rather long file\n", 400)
            })
          ])
        )

        Fixtures.record_turn(
          context.scope,
          Fixtures.user_request("and now the next thing"),
          Fixtures.model_response([%{"type" => "text", "text" => "Done with the file."}])
        )

        {:ok, context}
      end

      then_ "the rendered arguments are cut", context do
        {:ok, view, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope))

        assert has_element?(view, "[data-test='tool-call'][data-truncated='true']"),
               "a payload this size has to be cut or it is the whole page"

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the transcript says it was cut rather than looking complete", context do
        assert context.html =~ "truncated",
               "a record that silently omits is worse than one that omits and says so"

        {:ok, context}
      end

      then_ "the turn after it is still reachable", context do
        assert context.html =~ "Done with the file.",
               "burying the following turn is the failure this criterion names"

        {:ok, context}
      end
    end
  end
end

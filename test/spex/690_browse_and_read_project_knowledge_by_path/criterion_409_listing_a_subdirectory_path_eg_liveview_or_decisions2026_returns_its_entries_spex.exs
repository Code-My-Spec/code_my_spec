defmodule CodeMySpecSpex.Story690.Criterion5964Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5964 — Calling list_knowledge with a subdirectory path
  returns the directory listing at that level.

  Surface: ListKnowledge MCP tool.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "list_knowledge returns the entries at a subdirectory", criterion: 409 do
    scenario "Calling list_knowledge with path \"liveview\" returns entries in priv/knowledge/liveview/" do
      when_ ~s(the agent calls list_knowledge with path "liveview"), context do
        response =
          ToolLibrary.run("list_knowledge", %{path: "liveview"}, %{scope: context.scope})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is not an error", context do
        assert {:ok, _text} = context.response,
               "expected list_knowledge to succeed, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the response body renders the subdirectory header and at least one entry", context do
        body = response_text(context.response)

        assert body =~ "liveview",
               "anchor: expected the subdirectory name in the listing header"

        # priv/knowledge/liveview contains numerous .md files; assert the
        # listing is non-empty by checking for the "- " markdown bullet
        # prefix used by format_entries/1.
        assert body =~ "\n- ",
               "expected at least one entry in the liveview directory listing, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end

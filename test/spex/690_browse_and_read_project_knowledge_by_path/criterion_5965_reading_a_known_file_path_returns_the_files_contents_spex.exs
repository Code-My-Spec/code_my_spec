defmodule CodeMySpecSpex.Story690.Criterion5965Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5965 — Calling read_knowledge with a known file path
  returns the file's actual markdown content.

  Surface: ReadKnowledge MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "read_knowledge returns the contents of a known file" do
    scenario "Reading priv/knowledge/README.md returns its content" do
      given_ "the disk content of priv/knowledge/README.md", context do
        path =
          :code_my_spec
          |> :code.priv_dir()
          |> Path.join("knowledge/README.md")

        expected = File.read!(path)

        {:ok, Map.put(context, :expected_content, expected)}
      end

      when_ ~s(the agent calls read_knowledge with path "README.md"), context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadKnowledge.execute(%{path: "README.md"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is not an error", context do
        refute context.response.isError == true,
               "expected read_knowledge to succeed, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the response body equals the file's content", context do
        body = response_text(context.response)

        assert body == context.expected_content,
               "expected response body to equal README.md content"

        {:ok, context}
      end
    end
  end
end

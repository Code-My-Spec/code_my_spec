defmodule CodeMySpecSpex.Story711.Criterion6245Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6245 — Sync against a populated working directory returns a file and component summary.

  When the working directory has at least one tracked source file under
  `lib/` and the agent calls `sync_project`, the response text reports
  a non-zero file count and a component count.

  Surface: `SyncProject` MCP tool. Files are seeded via
  `Environments.write_file/3` against the test scope's memory
  environment — the same surface other sync tests (story 127) use.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.SyncProject

  @impl_path "lib/example_bootstrap.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "sync_project rebuilds the requirement graph and returns a file/component summary" do
    scenario "Sync against a populated working directory returns a file and component summary" do
      given_ "the working directory has at least one tracked source file under lib/", context do
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())
        {:ok, context}
      end

      when_ "the agent calls sync_project", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = SyncProject.execute(%{}, frame)
        {:ok, Map.put(context, :sync_response, response)}
      end

      then_ "the response text reports a non-zero file count", context do
        body = response_text(context.sync_response)

        assert body =~ ~r/Files:\s*[1-9]\d*/,
               "expected response to report a non-zero file count, got:\n#{body}"

        {:ok, Map.put(context, :response_body, body)}
      end

      and_ "the response text reports a component count", context do
        body = context.response_body

        assert body =~ ~r/Components:\s*\d+/,
               "expected response to report a component count, got:\n#{body}"

        {:ok, context}
      end
    end
  end

  defp impl_content do
    """
    defmodule ExampleBootstrap do
      @moduledoc false
    end
    """
  end
end

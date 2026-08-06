defmodule CodeMySpecSpex.Story987.Criterion8194Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8194 — A tool that needs a working copy refuses instead of using the
  server's.

  Covers Rule "The server never resolves a project's files against its own
  working directory."

  Three separate paths built a `:local` environment rooted at `File.cwd!()` when
  the scope had none. On a developer's machine that is the project; on a server
  it is the server's own checkout. `install_agents_md` answered "Installed:
  .code_my_spec/AGENTS.md" — truthfully — having written it into the CodeMySpec
  repository, and `SpecStub` left eight `e2e_todo` spec files there.

  The expensive half was the mirror image: the agent's own spec directory stayed
  empty, so every component it created had no dependency edges, read as an
  orphan, and made `architecture_designed` unsatisfiable.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A server with no working copy says so rather than using its own" do
    scenario "creating a component hands the stub back instead of writing it somewhere" do
      given_ "the server holds no working copy for the project", context do
        {:ok, Map.put(context, :scope, %{context.scope | environment: nil, cwd: nil})}
      end

      when_ "a component is created", context do
        {:ok,
         Map.put(
           context,
           :result,
           Fixtures.write_component_stub(context.scope, %{
             module_name: "MyApp.Widgets",
             type: :context,
             description: "Stores widgets."
           })
         )}
      end

      then_ "it refuses rather than writing into the server's own checkout", context do
        assert context.result == {:error, :no_working_copy},
               """
               Writing here would put one project's files into another's
               repository, and the agent's own directory would stay empty — which
               is how fifteen requirements stayed unsatisfiable while the agent
               did everything correctly.
               """

        {:ok, context}
      end
    end
  end
end

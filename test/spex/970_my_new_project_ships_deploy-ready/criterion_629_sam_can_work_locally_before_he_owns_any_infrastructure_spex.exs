defmodule CodeMySpecSpex.Story970.Criterion629Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready.
  Criterion 629 — Sam can work locally before he owns any infrastructure.

  Generate the application with cms.new, start it in development mode, and
  request its health route. The project has no Hetzner, Cloudflare, or Resend
  setup; the local boot must not require those accounts.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :drill_working_directory

  spex "Sam can work locally before he owns any infrastructure", criterion: 629 do
    scenario "a fresh project starts and serves a request without provider credentials" do
      given_ "Sam has generated a project and configured no provider credentials", context do
        assert "mix.exs" in project_tree(context.execution_context),
               "expected cms.new to generate a local application"

        {:ok, context}
      end

      when_ "he starts it locally", context do
        code = """
        app = Mix.Project.config()[:app]
        router = Module.concat([Macro.camelize(to_string(app)) <> "Web", "Router"])
        conn = Plug.Test.conn(:get, "/health")
        response = router.call(conn, router.init([]))
        IO.puts("LOCAL_HEALTH_STATUS=\#{response.status}")
        """

        {output, status} =
          Fixtures.env_cmd(context.execution_context, "mix", ["run", "-e", code])

        {:ok, Map.merge(context, %{output: output, exit_status: status})}
      end

      then_ "it boots and serves requests", context do
        assert context.exit_status == 0,
               "expected the generated app to boot locally, got: #{context.output}"

        assert context.output =~ "LOCAL_HEALTH_STATUS=200",
               "expected the generated app to serve its health route, got: #{context.output}"

        {:ok, context}
      end

      then_ "nothing demands a Hetzner, Cloudflare, or Resend account", context do
        refute context.output =~
                 ~r/(Hetzner|Cloudflare|Resend).*(credential|API key|account).*(required|missing)/i,
               "expected local startup to be independent of infrastructure accounts"

        {:ok, context}
      end
    end
  end
end

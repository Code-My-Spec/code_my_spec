defmodule CodeMySpecSpex.Story1108.Criterion4665Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4665 — The harness starts the app with its port and database.

  Rule: An app declares how it starts with a recipe that honors PORT and
  DATABASE_NAME.

  See criterion 4666 for the other half of this rule (a copy with no start
  recipe).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "Launch is handed a port, an https port and a database name", criterion: 1541 do
    scenario "an ordinary copy starting for the first time" do
      given_ "a working copy with a serve recipe", context do
        rig = app_instance_rig(database_exists?: true)
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app comes up serving", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "launch was given a real port, https port and database name", context do
        assert [
                 {:launch,
                  [root, port, https_port, database, _log_path, _main?, _tunnel_held?, _host]}
               ] =
                 Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))

        assert root == context.root
        assert is_integer(port) and port > 0
        assert is_integer(https_port) and https_port > 0

        assert https_port != port,
               "the two need separate ports — one HTTPS_PORT bug already cost a real start"

        assert is_binary(database) and database != ""

        {:ok, context}
      end
    end
  end
end

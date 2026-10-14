defmodule CodeMySpecSpex.Story1112.Criterion2041Spex do
  @moduledoc "Desktop setup presents its checks and contextual main-agent assistance together."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Desktop setup assistance distinguishes legacy history from current connectivity",
    criterion: 2041 do
    scenario "A legacy disconnected snapshot is historical when help is requested on a live connection" do
      given_ "completed checks and a legacy connection snapshot on disk", context do
        context =
          Map.merge(
            context,
            CodeMySpecSpex.Fixtures.desktop_setup_main_agent(context.desktop_user)
          )

        project = CodeMySpecSpex.Fixtures.desktop_setup_connected_harness(context.scope)
        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)

        path =
          view
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")
          |> hd()

        snapshot = context |> read_machine_file!(path) |> Jason.decode!()
        captured_at = "2026-01-01T00:00:00Z"

        historical =
          Map.put(snapshot, "operations", %{
            "connect" => %{
              "state" => "done",
              "started_at" => captured_at,
              "finished_at" => captured_at,
              "result" => %{
                "id" => project.id,
                "working_copy_id" => project.working_copy_id,
                "root" => project.root,
                "connected" => false
              }
            }
          })

        bytes = Jason.encode!(historical, pretty: true)
        :ok = Environments.write_file(context.machine_environment, path, bytes)

        {:ok,
         Map.merge(context, %{
           history: historical,
           history_bytes: bytes,
           results_path: path,
           commands_before: read_machine_file!(context, context.command_log)
         })}
      end

      when_ "the developer reopens setup and requests assistance", context do
        {:ok, view, _} = live(context.conn, "/app")
        assert has_element?(view, "[data-test='project-connected']")
        view |> element("[data-test='accept-install-help']") |> render_click()
        render_async(view, 10_000)
        agent_id = context.setup_main_agent.id
        assert_receive {:agent_dispatch, ^agent_id, _ref, request}, 5_000
        [instructions, encoded] = String.split(request, "\n\n", parts: 2)
        {:ok, Map.merge(context, %{instructions: instructions, payload: Jason.decode!(encoded)})}
      end

      then_ "the agent receives separate live connectivity and unchanged historical results",
            context do
        assert context.payload["recorded_setup"] == context.history
        assert context.payload["current_connection"]["connected"] == true
        assert context.payload["current_connection"]["connection_state"] == "connected"

        assert {:ok, _, _} =
                 DateTime.from_iso8601(context.payload["current_connection"]["observed_at"])

        assert context.instructions =~
                 "historical connected=false is not evidence of a current connection failure"

        assert context.instructions =~ "connect operation's finished_at for older records"
        assert read_machine_file!(context, context.results_path) == context.history_bytes
        assert read_machine_file!(context, context.command_log) == context.commands_before
        {:ok, context}
      end
    end
  end

  spex "Setup runs in the desktop UI with the main agent assisting", criterion: 2041 do
    scenario "A failed prerequisite is readable beside the main agent's help" do
      given_ "the developer opens desktop setup on a machine missing pgvector", context do
        DesktopSetupHelpers.without_pgvector(context)

        context =
          Map.merge(
            context,
            CodeMySpecSpex.Fixtures.desktop_setup_main_agent(context.desktop_user)
          )

        {:ok, view, _} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the developer runs the prerequisite checks from the desktop", context do
        context.view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.view, 10_000)
        context.view |> element("[data-test='accept-install-help']") |> render_click()
        render_async(context.view, 10_000)

        agent_id = context.setup_main_agent.id
        assert_receive {:agent_dispatch, ^agent_id, _ref, request}, 5_000
        assert request =~ "pgvector is not installed"
        assert request =~ "results_path"

        :ok =
          CodeMySpecSpex.Fixtures.agent_said(
            context.scope,
            context.setup_main_agent,
            "pgvector is missing. I can help install the extension for your PostgreSQL version."
          )

        {:ok, context}
      end

      then_ "the desktop displays the steps and their actual command outcomes", context do
        assert has_element?(context.view, "[data-test='desktop-setup']")

        assert has_element?(
                 context.view,
                 "[data-test='prerequisite'][data-name='pgvector'][data-state='missing']"
               )

        failed_step =
          context.view
          |> element("[data-test='prerequisite'][data-name='pgvector']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert failed_step =~ "pgvector is not installed"
        assert has_element?(context.view, "[data-test='setup-results-file'][data-path]")
        assert read_machine_file!(context, context.command_log) =~ ~r/^psql .*vector/m
        {:ok, context}
      end

      then_ "the main agent explains the missing prerequisite and offers installation help on that page",
            context do
        assert has_element?(context.view, "[data-test='setup-agent-help'][data-role='main']")

        explanation =
          context.view
          |> element("[data-test='setup-agent-help'][data-role='main']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert explanation =~ ~r/pgvector/i
        assert explanation =~ ~r/install/i

        assert has_element?(
                 context.view,
                 "[data-test='setup-agent-help'] [data-test='accept-install-help']:not([disabled])"
               )

        assert has_element?(
                 context.view,
                 "[data-test='prerequisite'][data-name='pgvector'] [data-test='install-instructions']"
               )

        refute has_element?(context.view, "[data-test='project-connected']")
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end

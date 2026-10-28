defmodule CodeMySpecSpex.Story1172.Criterion2561Spex do
  @moduledoc "Story 1172: Every running and queued analyzer execution is visible across copies."

  use CodeMySpecSpex.Case, async: false

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees two copies' runs in flight and the request riding on one of them",
    criterion: 2561 do
    scenario "a shared spex execution and a queued credo execution" do
      given_ "team B's copy is running a full spex run that a promotion and an agent both asked for",
             context do
        {:ok,
         Map.put(context, :runs, Fixtures.analysis_dashboard_two_copies_in_flight(context.scope))}
      end

      and_ "security's copy is running exunit with credo queued behind it", context do
        on_exit(Fixtures.stub_analysis_dashboard_harness(context.runs))
        {:ok, context}
      end

      when_ "John opens what the analyzer is running", context do
        {:ok, view, _html} = live(context.conn, "/dev/analysis")
        {:ok, Map.put(context, :view, view)}
      end

      then_ "he sees both copies' running runs, credo queued behind security's exunit", context do
        rows =
          context.view
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-test=analysis-run-row]")

        assert Enum.any?(
                 rows,
                 &(text(&1) =~ "team-b" and text(&1) =~ "spex" and text(&1) =~ "running")
               )

        assert Enum.any?(
                 rows,
                 &(text(&1) =~ "security" and text(&1) =~ "exunit" and text(&1) =~ "running")
               )

        assert Enum.any?(
                 rows,
                 &(text(&1) =~ "security" and text(&1) =~ "credo" and text(&1) =~ "queued")
               )

        {:ok, context}
      end

      and_ "that team B's spex run serves both the promotion and the agent", context do
        rows =
          context.view
          |> render()
          |> Floki.parse_document!()
          |> Floki.find("[data-test=analysis-run-row]")

        shared = Enum.find(rows, &(text(&1) =~ "team-b" and text(&1) =~ "spex"))
        assert shared
        assert text(shared) =~ to_string(context.runs.spex.id)
        assert text(shared) =~ to_string(context.runs.agent_request.id)
        {:ok, context}
      end
    end
  end

  defp text(node), do: Floki.text(node)
end

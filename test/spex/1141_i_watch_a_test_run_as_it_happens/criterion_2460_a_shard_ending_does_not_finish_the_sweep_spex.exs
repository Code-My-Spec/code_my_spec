defmodule CodeMySpecSpex.Story1141.Criterion2460Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2460 — A shard ending does not finish the sweep.
  """

  use CodeMySpecSpex.Case, async: false

  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A shard ending does not finish the sweep", criterion: 2460 do
    scenario "one completed shard leaves the other three and the sweep running" do
      given_ "a full spex sweep runs as 4 cms.spex shards", context do
        {:ok, start_sweep(context)}
      end

      when_ "one shard has run all its tests and the other three are still running",
            context do
        Enum.each(context.files, fn file ->
          report(context, %{"event" => "file_started", "file" => file})
        end)

        report(context, %{
          "event" => "test",
          "file" => hd(context.files),
          "name" => "first shard passes",
          "state" => "passed"
        })

        report(context, %{"event" => "file_finished", "file" => hd(context.files)})
        {:ok, context}
      end

      then_ "the run is still running while three shards remain", context do
        live = read_live(context)
        assert live["run_id"] == context.run_id
        assert live["status"] == "running"
        assert live["live"] == "streaming"
        assert live["tests"]["passed"] == 1
        assert Enum.sort(live["running_files"]) == Enum.sort(tl(context.files))
        {:ok, context}
      end
    end

    scenario "the sweep finishes when cms.spex exits" do
      given_ "a full spex sweep has run as 4 cms.spex shards", context do
        context = start_sweep(context)

        Enum.each(context.files, fn file ->
          report(context, %{"event" => "file_started", "file" => file})

          report(context, %{
            "event" => "test",
            "file" => file,
            "name" => "passes in #{file}",
            "state" => "passed"
          })

          report(context, %{"event" => "file_finished", "file" => file})
        end)

        {:ok, context}
      end

      when_ "cms.spex exits", context do
        report(context, %{"event" => "finished"})
        {:ok, context}
      end

      then_ "get_analysis_live reports the sweep finished, with all shard results", context do
        live = read_live(context)
        assert live["run_id"] == context.run_id
        assert live["live"] == "finished"
        assert live["tests"]["passed"] == 4
        assert live["running_files"] == []
        {:ok, context}
      end
    end
  end

  defp start_sweep(context) do
    run = Fixtures.start_analysis_run(context.scope, "spex")

    {:ok, _reply, channel} =
      UserSocket
      |> socket("spex_sweep_harness", %{scope: context.scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{context.scope.active_project_id}",
        %{
          "label" => "the harness running cms.spex",
          "harness_id" => context.scope.active_working_copy_id
        }
      )

    files = for shard <- 1..4, do: "test/spex/shard_#{shard}_spex.exs"
    Map.merge(context, %{run_id: run.id, channel: channel, files: files})
  end

  defp report(context, event) do
    ref =
      Phoenix.ChannelTest.push(context.channel, "analysis_event", %{
        "run_id" => context.run_id,
        "event" => event
      })

    assert_reply ref, :ok
  end

  defp read_live(context) do
    tool_context = %{scope: context.scope, current_scope: context.scope}

    assert {:ok, body} =
             ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

    Jason.decode!(body)
  end
end

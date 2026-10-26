defmodule CodeMySpecSpex.Story1141.Criterion2459Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2459 — Four spex shards stream into one run.
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

  spex "Four spex shards stream into one run", criterion: 2459 do
    scenario "the live tool retains a passing test and running file from every shard" do
      given_ "a full spex sweep runs as 4 cms.spex shards", context do
        run = Fixtures.start_analysis_run(context.scope, "spex")

        {:ok, _reply, channel} =
          UserSocket
          |> socket("sharded_spex_harness", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessProjectChannel,
            "harness_project:#{context.scope.active_project_id}",
            %{
              "label" => "the harness running four cms.spex shards",
              "harness_id" => context.scope.active_working_copy_id
            }
          )

        files = for shard <- 1..4, do: "test/spex/shard_#{shard}_spex.exs"
        {:ok, Map.merge(context, %{run_id: run.id, channel: channel, files: files})}
      end

      when_ "each shard reports a different passing test", context do
        Enum.with_index(context.files, 1)
        |> Enum.each(fn {file, shard} ->
          for event <- [
                %{"event" => "file_started", "file" => file, "node" => "cms_spex_#{shard}"},
                %{
                  "event" => "test",
                  "file" => file,
                  "name" => "shard #{shard} passes",
                  "state" => "passed",
                  "node" => "cms_spex_#{shard}"
                }
              ] do
            ref =
              Phoenix.ChannelTest.push(context.channel, "analysis_event", %{
                "run_id" => context.run_id,
                "event" => event
              })

            assert_reply ref, :ok
          end
        end)

        {:ok, context}
      end

      then_ "get_analysis_live shows all four passing tests and all four running files on the same run",
            context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        assert {:ok, body} =
                 ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        live = Jason.decode!(body)

        assert live["run_id"] == context.run_id
        assert live["source"] == "spex"
        assert live["status"] == "running"
        assert live["live"] == "streaming"
        assert live["tests"]["reported"] == 4
        assert live["tests"]["passed"] == 4
        assert Enum.sort(live["running_files"]) == Enum.sort(context.files)
        {:ok, context}
      end
    end
  end
end

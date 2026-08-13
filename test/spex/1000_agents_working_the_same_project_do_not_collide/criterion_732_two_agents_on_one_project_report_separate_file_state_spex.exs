defmodule CodeMySpecSpex.Story1000.Criterion732Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 732 — Two agents on one project report separate file state.

  Rule: An agent's files, problems and components belong to that agent alone.

  Files, problems and components are projections of a working copy but are keyed
  by project, so two agents on one project write the same rows. The visible cost
  is an agent's stop hook reporting work it never did: a failing test recorded by
  one checkout blocks the other, and the only compliant response available to the
  blocked agent is to fix code it does not own.

  Surfaces, and both are needed because the criterion spans both.

  A working copy becomes an agent by **joining the channel** — join is where
  identity is issued — so that is how the two agents are established. Registering
  one over HTTP would be asserting against a mechanism the product does not use
  for this.

  What each agent is *told* arrives through its stop hook, keyed by
  `x-harness-id`. That is the thing the criterion says must differ.

  Hooks live on `CodeMySpecLocalWeb`; the channel lives on `CodeMySpecWeb`.
  `@endpoint` is what makes channels work and simultaneously makes `~p` hook
  posts resolve to the wrong router, so the hook calls dispatch explicitly.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  @contract_version 1

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel runs in its own process and cannot see an owner-only
    # connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One agent's failing test is that agent's problem" do
    scenario "Two agents on one project report separate file state" do
      given_ "two agents are serving the same project from different working copies",
             context do
        topic = "harness_project:#{context.project.id}"

        # The first agent is this scope's own working copy — files and problems
        # are keyed on the harness, so a spec that writes through the channel and
        # reads through `scope` has to be the same checkout on both sides.
        {:ok, _reply, first} =
          UserSocket
          |> socket("harness_test_a", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, topic, %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_harness_id,
            "root" => "/workspace/first",
            "label" => "the harness at /workspace/first"
          })

        {:ok, second_reply, second} =
          UserSocket
          |> socket("harness_test_b", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, topic, %{
            "contract_version" => @contract_version,
            "harness_id" => nil,
            "root" => "/workspace/second",
            "label" => "the harness at /workspace/second"
          })

        second_id = second_reply["harness_id"] || second_reply[:harness_id]

        refute second_id == context.scope.active_harness_id,
               "two working copies must be two agents; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:first_socket, first)
         |> Map.put(:second_socket, second)
         |> Map.put(:second_harness_id, second_id)}
      end

      given_ "each has synced its own files", context do
        ref =
          Phoenix.ChannelTest.push(context.first_socket, "observations", %{
            "observations" => [
              %{
                "path" => "lib/first_only.ex",
                "role" => "implementation",
                "fingerprint" => "a",
                "mtime" => "2026-08-12T00:00:00.000000Z"
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _first_summary)

        ref =
          Phoenix.ChannelTest.push(context.second_socket, "observations", %{
            "observations" => [
              %{
                "path" => "lib/second_only.ex",
                "role" => "implementation",
                "fingerprint" => "b",
                "mtime" => "2026-08-12T00:00:00.000000Z"
              }
            ]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _second_summary)

        {:ok, context}
      end

      when_ "one agent's analyzer records a failing test", context do
        response =
          use_cmd_cassette "clean", record: :none do
            hook_post(context.scope.active_harness_id, context.scope.cwd, %{
              "session_id" => "spex-first-agent",
              "test_output_files" => %{
                "compile" =>
                  Path.expand("test/fixtures/validation/pipeline_exunit_failure/compile.jsonl"),
                "exunit" =>
                  Path.expand("test/fixtures/validation/pipeline_exunit_failure/exunit.json")
              }
            })
          end

        {:ok, Map.put(context, :first_agent_stop, response)}
      end

      then_ "that failure appears only in that agent's problems", context do
        assert context.first_agent_stop["decision"] == "block",
               "the agent that ran the failing test should be held by it, got: " <>
                 inspect(context.first_agent_stop)

        assert (context.first_agent_stop["reason"] || "") =~ "exunit",
               "expected the failing test in this agent's own block, got: " <>
                 inspect(context.first_agent_stop["reason"])

        {:ok, context}
      end

      then_ "the other agent's stop hook reports nothing about it", context do
        other =
          hook_post(context.second_harness_id, "/workspace/second", %{
            "session_id" => "spex-second-agent"
          })

        refute (other["reason"] || "") =~ "exunit",
               "the second agent was told about a failing test from a checkout it does not " <>
                 "have. The only compliant response available to it is to fix code it never " <>
                 "touched. Got: #{inspect(other)}"

        {:ok, context}
      end
    end
  end

  # Hooks are served by `CodeMySpecLocalWeb`, and `@endpoint` above points at
  # `CodeMySpecWeb` so the channel works — so these dispatch explicitly rather
  # than through `~p`, which would resolve against the wrong router.
  defp hook_post(harness_id, working_dir, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-working-dir", working_dir)
    |> Plug.Conn.put_req_header("x-harness-id", harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(
      CodeMySpecLocalWeb.Endpoint,
      :post,
      "/api/hooks/stop",
      params
    )
    |> Phoenix.ConnTest.json_response(200)
  end
end

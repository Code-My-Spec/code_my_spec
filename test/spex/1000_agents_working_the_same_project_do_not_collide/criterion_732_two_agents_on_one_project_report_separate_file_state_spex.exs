defmodule CodeMySpecSpex.Story1000.Criterion732Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 732 — Two agents on one project report separate file state.

  Rule: An agent's files, problems and components belong to that agent alone.

  Files, problems and components are projections of a working copy but were keyed
  by project, so two agents on one project wrote the same rows. The visible cost
  is an agent's stop hook reporting work it never did: a failing test recorded by
  one checkout blocks the other, and the only compliant response available to the
  blocked agent is to fix code it does not own.

  Surfaces, and both are needed because the criterion spans both.

  A working copy becomes an agent by **joining the channel** — join is where
  identity is issued — so that is how the second agent is established.
  Registering one over HTTP would be asserting against a mechanism the product
  does not use for this.

  What each agent is *told* arrives through its stop hook, keyed by
  `x-harness-id`. That is the thing the criterion says must differ.

  Hooks live on `CodeMySpecLocalWeb`; the channel lives on `CodeMySpecWeb`.
  `@endpoint` is what makes channels work and simultaneously makes `~p` hook
  posts resolve to the wrong router, so the hook calls dispatch explicitly.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()
  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"
  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

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
      # The first agent's checkout, populated and synced before any second
      # harness exists — the sync targets the most recently active working copy,
      # so establishing the rival first would file these files under it.
      given_ :synced_context_component
      given_ :on_configuration_page

      given_ "the project blocks on failing tests", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{exunit: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "two agents are serving the same project from different working copies",
             context do
        # A real second checkout on disk. Its emptiness is the point, and an
        # emptiness the analyzers can actually walk beats a path that only exists
        # in a string.
        {:ok, second_root} = Briefly.create(directory: true)

        {:ok, second_reply, second} =
          UserSocket
          |> socket("harness_test_b", %{scope: context.scope})
          |> subscribe_and_join(
            HarnessProjectChannel,
            "harness_project:#{context.project.id}",
            %{
              "contract_version" => @contract_version,
              "harness_id" => nil,
              "root" => second_root,
              "label" => "the harness at #{second_root}",
              "device" => %{"id" => Fixtures.device_fixture(context.scope).id}
            }
          )

        second_id = second_reply["harness_id"] || second_reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two working copies must be two agents; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:second_socket, second)
         |> Map.put(:second_root, second_root)
         |> Map.put(:second_working_copy_id, second_id)}
      end

      given_ "each has synced its own files", context do
        # The first agent's are already in place from `:synced_context_component`.
        # The second reports a tree of its own, which has neither the
        # implementation nor the test that is about to fail.
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

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok, context}
      end

      given_ "the first agent is working an implementation task", context do
        session_id = "spex-first-agent-#{System.unique_integer([:positive])}"

        post_hook(context.scope.active_working_copy_id, "/api/hooks/session-start", %{
          "session_id" => session_id
        })

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        # `started_at` has microsecond precision, so only a write after it counts
        # as changed during the task.
        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\nend\n"
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "one agent's analyzer records a failing test", context do
        response =
          use_cmd_cassette "pipeline_exunit_failure", record: :none do
            post_hook(context.scope.active_working_copy_id, "/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "compile" => fixture_path("compile.jsonl"),
                "exunit" => fixture_path("exunit.json")
              }
            })
          end

        {:ok, Map.put(context, :first_agent_stop, response)}
      end

      then_ "that failure appears only in that agent's problems", context do
        assert context.first_agent_stop["decision"] == "block",
               "the agent that ran the failing test should be held by it, got: " <>
                 inspect(context.first_agent_stop)

        assert (context.first_agent_stop["reason"] || "") =~ @test_path,
               "expected the failing test in this agent's own block, got: " <>
                 inspect(context.first_agent_stop["reason"])

        {:ok, context}
      end

      then_ "the other agent's stop hook reports nothing about it", context do
        # The second checkout is real and empty — its own stop still runs the
        # real pipeline (a real `mix compile` plus a real recursive `mix spex`,
        # see criterion 3059's note) unless driven the same way the first
        # agent's stop above is.
        other =
          use_cmd_cassette "clean", record: :none do
            post_hook(context.second_working_copy_id, "/api/hooks/stop", %{
              "session_id" => "spex-second-agent-#{System.unique_integer([:positive])}",
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "compile" =>
                  Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")
              }
            })
          end

        refute other["decision"] == "block",
               "the second agent was held by a failure from a checkout it does not have. " <>
                 "Got: #{inspect(other)}"

        # Named file rather than the word "exunit": the allow message lists the
        # analyzers it just enqueued, so matching on the source name would fire
        # on a healthy response and report a leak that is not there.
        refute inspect(other) =~ @test_path,
               "the second agent was told about a failing test in a file its working copy " <>
                 "does not contain. The only compliant response available to it is to fix " <>
                 "code it never touched. Got: #{inspect(other)}"

        {:ok, context}
      end
    end
  end

  # Hooks are served by `CodeMySpecLocalWeb`, and `@endpoint` above points at
  # `CodeMySpecWeb` so the channel works — so these dispatch explicitly rather
  # than through `~p`, which would resolve against the wrong router.
  #
  # No `x-working-dir`: the harness id names the working copy, and the server
  # answers where it is. Sending both would let a wrong root pass unnoticed.
  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end

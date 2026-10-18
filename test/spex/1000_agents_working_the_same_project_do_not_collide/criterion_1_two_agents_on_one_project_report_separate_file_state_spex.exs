defmodule CodeMySpecSpex.Story1000.Criterion732Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 732 — Two agents on one project report separate file state.

  Rule: An agent's files, problems and components belong to that agent alone.

  Files, problems and components are projections of a working copy but were keyed
  by project, so two agents on one project wrote the same rows. The visible cost
  is an agent being shown work it never did: a failing test recorded by one
  checkout listed as the other's, and the only compliant response available to
  that agent is to fix code it does not own.

  Surfaces, and both are needed because the criterion spans both.

  A working copy becomes an agent by **joining the channel** — join is where
  identity is issued — so that is how the second agent is established.
  Registering one over HTTP would be asserting against a mechanism the product
  does not use for this.

  What each agent *has* is its problems page, filtered to its working copy with
  `?harness=`. That is the thing the criterion says must differ. A stop no longer
  reports problems at all; they gate at promotion.

  Hooks live on `CodeMySpecLocalWeb`; the channel lives on `CodeMySpecWeb`.
  `@endpoint` is what makes channels work and simultaneously makes `~p` hook
  posts resolve to the wrong router, so the hook calls dispatch explicitly.
  """

  use CodeMySpecSpex.Case

  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"
  @failing_test """
  defmodule ExampleContextTest do
    use ExUnit.Case

    test "fails on purpose" do
      assert 1 == 2, "exunit failure fixture"
    end
  end
  """
  @fixture_dir "test/fixtures/validation/pipeline_exunit_failure"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel runs in its own process and cannot see an owner-only
    # connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One agent's failing test is that agent's problem", criterion: 1 do
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
        # Each checkout served by its own live harness. The first holds what
        # `:synced_context_component` put in place; the second is a real checkout
        # of its own, which has neither the implementation nor the test that is
        # about to fail.
        context = HarnessHooks.ensure_live_harness(context)

        second =
          HarnessHooks.given_a_live_harness(context,
            files: %{"lib/second_only.ex" => "defmodule SecondOnly do\nend\n"}
          )

        refute second.harness.working_copy_id == context.harness.working_copy_id,
               "two working copies must be two agents; the server issued one id for both"

        {:ok, Map.put(context, :second, second)}
      end

      given_ "each has synced its own files", context do
        # What each harness's scan reported when it joined: the first agent's
        # implementation and test, and the second's own file. The second
        # reporting a change of its own is the same channel, observed.
        HarnessHooks.write_file(
          context.second,
          "lib/second_only.ex",
          "defmodule SecondOnly do\n  @moduledoc false\nend\n"
        )

        {:ok, context}
      end

      given_ "the first agent is working an implementation task", context do
        session_id = "spex-first-agent-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

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

        # It writes the implementation and the test that is about to fail: the
        # failure is on a file this agent edited, so it is this agent's.
        context = Map.put(context, :session_id, session_id)

        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\n  @moduledoc false\nend\n"
          )

        :ok = record_edit(context, @impl_path)

        :ok =
          Environments.write_file(
            context.environment,
            @test_path,
            @failing_test
          )

        :ok = record_edit(context, @test_path)

        {:ok, context}
      end

      when_ "one agent's analyzer records a failing test", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))
        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))

        {:ok, context}
      end

      then_ "that failure appears only in that agent's problems", context do
        assert problems_page(context, context.harness.working_copy_id) =~ @test_path,
               "expected the failing test among this agent's own problems"

        {:ok, context}
      end

      then_ "the other agent's problems say nothing about it", context do
        # The second checkout is real and empty — its own stop still runs the
        # real pipeline (a real `mix compile` plus a real recursive `mix spex`,
        # see criterion 3059's note) unless driven the same way the first
        # agent's stop above is.
        # The second checkout's own analyzers, clean, as they report from there.
        HarnessHooks.land_analysis(
          context.second,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(
          context.second,
          "compiler",
          Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")
        )

        refute problems_page(context, context.second.harness.working_copy_id) =~ @test_path,
               "the second agent is shown a failing test in a file its working copy " <>
                 "does not contain. The only compliant response available to it is to fix " <>
                 "code it never touched."

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp problems_page(context, copy_id) do
    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/problems?harness=#{copy_id}")

    html
  end
end

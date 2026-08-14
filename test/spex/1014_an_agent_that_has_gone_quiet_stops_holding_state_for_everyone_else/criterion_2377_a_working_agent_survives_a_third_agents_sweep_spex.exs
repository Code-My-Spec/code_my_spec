defmodule CodeMySpecSpex.Story1014.Criterion2377WorkingAgentSpex do
  @moduledoc """
  Story 1014 — Criterion 2377 — A working agent is never reclaimed out from
  under itself.

  Rule: The agent doing the syncing is live by definition and is excluded from
  its own sweep.

  The sibling spex covers the caller excluding itself. This covers what that
  exclusion cannot reach: a *third* agent sweeps, and the victim is a different
  agent who is also working.

  It exists because QA found the story shipping with that hole open.
  `last_seen_at` was written only on channel join and on onboarding, so it
  recorded when a harness last *connected* rather than when its agent last did
  anything — and a harness holding a stable channel never reconnects. Measured
  on the live project, two harnesses whose agents were mid-session read 2:21 and
  2:25 idle against a two hour window, having only ever run down. The next sync
  from any third agent would have deleted both agents' state underneath them,
  which is the failure the whole story exists to prevent, arriving through the
  liveness signal instead of through row age.

  So liveness has to be renewed by evidence of work, and a hook is that
  evidence.

  ## Surface

  `POST /api/hooks/stop` on `CodeMySpecLocalWeb`, from two different harnesses,
  and the components page to see what survived.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  @spec_path ".code_my_spec/spec/worker_context.spec.md"
  @impl_path "lib/worker_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Working is what keeps an agent alive, not connecting" do
    scenario "A third agent's sweep spares an agent that is still working" do
      given_ :synced_context_component

      given_ "an agent with a component only its own checkout carries", context do
        worker = Fixtures.live_agent_scope(context.scope, label: "the agent still working")

        :ok = Environments.write_file(worker.environment, @spec_path, spec_file())
        :ok = Environments.write_file(worker.environment, @impl_path, impl_file())

        # Its own stop is what projects the component, under its own harness.
        hook(worker, %{"session_id" => "spex-worker-sync-#{unique()}"})

        {:ok, Map.put(context, :worker, worker)}
      end

      given_ "every checkout on the project is long past the idle window", context do
        # Including the worker's. Nothing has re-joined a channel, which is the
        # ordinary state of a machine that has been up all day.
        Fixtures.all_agents_go_quiet(context.scope, 96)
        {:ok, context}
      end

      given_ "the worker does some work, which is the only proof it is here", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.worker.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/stop", %{
          "session_id" => "spex-worker-#{unique()}"
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      when_ "a third agent stops, sweeping everyone it believes is quiet", context do
        third = Fixtures.live_agent_scope(context.scope, label: "the third agent")
        hook(third, %{"session_id" => "spex-third-#{unique()}"})
        {:ok, context}
      end

      then_ "the working agent's component is still there", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "WorkerContext",
               "a working agent was reclaimed by a third agent's sweep. Its own " <>
                 "hook had just proved it was here, so the sweep read liveness from " <>
                 "something that work does not renew — `last_seen_at` written only " <>
                 "on channel join, which a stable connection never repeats. " <>
                 "Excluding the caller does not cover this: the caller is not the " <>
                 "victim."

        {:ok, context}
      end
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp hook(scope, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/stop", params)
    |> Phoenix.ConnTest.json_response(200)
  end

  defp spec_file do
    """
    # WorkerContext

    ## Type

    context

    A context carried only by the working agent's checkout.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None
    """
  end

  defp impl_file do
    """
    defmodule WorkerContext do
      @moduledoc "A context carried only by the working agent's checkout."

      @spec noop() :: :ok
      def noop, do: :ok
    end
    """
  end
end

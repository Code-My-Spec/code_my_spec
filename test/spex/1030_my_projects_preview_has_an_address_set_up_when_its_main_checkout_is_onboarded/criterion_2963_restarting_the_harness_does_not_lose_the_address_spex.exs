defmodule CodeMySpecSpex.Story1030.Criterion2963Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2963 — Restarting the harness does not lose the address.

  Rule: The preview address survives the harness restarting, because it is
  written down rather than held in memory.

  A harness restarts constantly — `just refresh-harness` alone does it several
  times an hour on this machine. An address held in memory would come back empty
  every time, and the founder would find the preview gone for no reason they
  could observe, with the fix being to onboard a checkout that is already
  onboarded.

  ## Why a rejoin is the test and a reload is not

  Reloading the page proves the server persisted it. That is the weaker half.
  The claim is that the *checkout* still knows, so the evidence has to be a
  harness that has gone away and come back reporting the same address without
  being told it again — which is only possible if it read it off disk.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  # The panel lives in `CodeMySpecWeb`, not the local app the case template
  # points at by default. Without this the route 404s and `live/2` fails
  # inside LiveViewTest rather than saying which router it looked in.
  # Story 1025's criteria drive the same page and override it the same way.
  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.MainAgentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The agent runs in another process, so it needs the connection this one
    # holds.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # Without a provider the main agent is refused, no conversation is ever
  # created, and the preview panel has no page to sit beside. The refusal is
  # deliberate — an agent started on a credential that does not resolve fails on
  # its first model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  @url "https://preview-2963.example.test"

  spex "A preview address outlives the process that reported it" do
    scenario "Restarting the harness does not lose the address" do
      given_ "a project whose main checkout reports where its preview answers", context do
        context = given_a_main_checkout(context, "spex_2963", preview_url: @url)

        {:ok, Map.put(context, :path, say_to_main_agent(context, "how is it going"))}
      end

      # The real restart surface: every agent on the machine is stopped and the
      # harness brings back what it is still serving. Driven through the harness
      # rather than reconstructed here, so the refusals a restart inherits are
      # the ones a restart actually produces.
      when_ "the machine running it restarts", context do
        restart_harness(context.harness_socket)

        {:ok, context}
      end

      then_ "the founder's preview is still where it was", context do
        {:ok, live, _html} = live(context.conn, context.path)

        html = live |> element("[data-test='panel-tab-preview']") |> render_click()

        assert html =~ @url,
               "the address did not survive the restart. A harness restarts many " <>
                 "times an hour, so a preview that does not outlive one is a preview " <>
                 "that is usually missing — and the only apparent remedy is to onboard " <>
                 "a checkout that is already onboarded."

        {:ok, context}
      end
    end
  end
end

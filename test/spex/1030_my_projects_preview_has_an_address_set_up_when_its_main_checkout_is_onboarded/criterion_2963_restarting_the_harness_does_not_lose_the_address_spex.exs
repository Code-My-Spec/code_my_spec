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

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments

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

  @harness_config ".cms_harness.json"
  @url "https://preview-2963.example.test"

  spex "A preview address outlives the process that reported it" do
    scenario "Restarting the harness does not lose the address" do
      given_ "a checkout whose config names where its preview answers", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            @harness_config,
            Jason.encode!(
              %{
                working_copy_id: "spex-harness-2963",
                project_id: context.project.id,
                preview_url: @url
              },
              pretty: true
            )
          )

        reply =
          join_working_copy(context, "/workspace/main", "main",
            working_copy_id: "spex-harness-2963",
            preview_url: @url
          )

        {:ok, Map.put(context, :working_copy_id, reply.working_copy_id)}
      end

      when_ "the harness goes away and comes back, reading only its own config", context do
        # The restart. Nothing carries over between these two joins except what
        # is on disk, which is the whole point — a second join that had to be
        # handed the address again would prove nothing about it being written
        # down.
        {:ok, config} =
          Environments.read_file(context.environment, @harness_config)

        recorded = Jason.decode!(config)["preview_url"]

        reply =
          join_working_copy(context, "/workspace/main", "main-again",
            working_copy_id: "spex-harness-2963",
            preview_url: recorded
          )

        {:ok, Map.put(context, :rejoined, reply.working_copy_id)}
      end

      then_ "the project's preview is still where it was", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

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

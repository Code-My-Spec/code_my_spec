defmodule CodeMySpecSpex.Story1024.Criterion4643Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 4643 — The turn fails mid-reply; the draft goes and the failure
  shows.

  Rule: An agent's reply appears as it is written, and becomes the message when
  it is done.

  The failure path. A reply that never finishes never becomes a message, so
  nothing replaces the draft — and a draft left standing reads as an agent
  still writing, which is the one thing a failed turn must not look like.

  Driven by a provider that drops the connection part-way through the reply.
  `Alloy.Provider.Retry` does not retry a stream that already produced output,
  so the turn fails the way it does when a provider goes away mid-sentence.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A reply that fails does not look unfinished", criterion: 1522 do
    scenario "The turn fails mid-reply; the draft goes and the failure shows" do
      given_ "an agent part-way through a reply I am watching", context do
        copy = CodeMySpec.TempFile.dir("spex_4643")
        RealDisk.mkdir_p!(copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_4643", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        context = agent_on_held_provider(context, socket, copy)
        {:ok, live, _html} = live(context.conn, context.conversation_path)
        context = Map.put(context, :live, live)
        :ok = reply_part_way(context)

        eventually(fn ->
          assert has_element?(live, "#agent-writing", HeldProvider.reply_so_far()),
                 "the premise is a reply on the page part-way through"
        end)

        {:ok, context}
      end

      when_ "its turn fails", context do
        HeldProvider.drop()
        await_quiet(context)
        {:ok, context}
      end

      then_ "the draft is no longer shown", context do
        eventually(fn ->
          refute has_element?(context.live, "#agent-writing"),
                 "the turn failed and the page still shows the reply being written — " <>
                   "an operator reads that as an agent still thinking"
        end)

        {:ok, context}
      end

      then_ "and the page says the turn failed", context do
        # The transport's own words, in a message. The page is full of "error"
        # and "failed" — flash containers, form markup — and an assertion that
        # matches those passes over a transcript that says nothing.
        eventually(fn ->
          assert has_element?(context.live, "[data-test=message]", "HTTP request failed"),
                 "the turn failed and the page does not say so. Got: " <>
                   (context.live |> render() |> String.slice(0, 400))
        end)

        {:ok, context}
      end
    end
  end
end

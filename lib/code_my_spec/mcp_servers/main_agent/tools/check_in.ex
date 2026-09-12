defmodule CodeMySpec.McpServers.MainAgent.Tools.CheckIn do
  @moduledoc """
  Look in on your agents now, without waiting for the next scheduled wake-up.

  The same digest the cadence delivers — what every agent is working on, the
  health of the machinery under them, and every question waiting on somebody.
  Assembled from all three, so a failure in any one of them is reported as a
  failure rather than as a shorter list: an empty digest and an unbuildable one
  read identically, and only one of them is good news.

  The cadence is a floor, never a schedule — the longest anything can go unseen.
  Nothing here waits for it: a question raised now is pushed now, and this is
  how you look when you have a reason to rather than when the timer says so.
  """

  # Story 1059's check-in had no agent-facing surface at all — it existed only as
  # a context function reached by the timer and, in the spex, through the
  # in-process Fixtures bridge. So "the wake-up says what is going on" and "a
  # digest that cannot be assembled is not delivered as an empty one" could not
  # be observed from outside the BEAM, which is where QA has to stand.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, deliver(MainAgent.check_in(scope)), frame}
      {:error, reason} -> {:reply, refusal(reason), frame}
    end
  end

  # `check_in/1` answers `:ok` whatever happens, and that is deliberate rather
  # than thin: the digest is delivered into the main agent's conversation, and a
  # digest that could not be assembled raises a fault there instead. So this
  # reports that a check-in ran and says where to read it, rather than inventing
  # a return value the context does not have.
  #
  # The first cut of this had `{:ok, text}` and `{:error, reason}` clauses
  # written against a contract that does not exist. The compiler called them
  # unreachable, which was right — they were speculative error handling for a
  # function that cannot fail that way.
  defp deliver(:ok) do
    Response.text(
      Response.tool(),
      """
      Checked in.

      The digest went to the main agent's conversation rather than coming back
      here — that is where the cadence delivers it too, so what you read there is
      what a scheduled wake-up would have said.

      If it could not be assembled, a fault was raised on the conversation
      instead of an empty all-quiet. An empty digest and an unbuildable one read
      identically, and only one of them is good news.
      """
    )
  end

  defp refusal(reason) do
    Response.error(
      Response.tool(),
      "Could not check in: #{inspect(reason)}"
    )
  end
end

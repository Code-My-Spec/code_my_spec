defmodule CmsHarness.Browser.Dialog do
  @moduledoc """
  Clears a native `alert`, `confirm` or `prompt` a browser call left open, and
  says so in the answer.

  vibium starts Chrome with `unhandledPromptBehavior: ignore` and no way to
  change it. A click that opens `confirm()` does not return until vibium's own
  `input.performActions` gives up a minute later, with an error that does not
  mention a dialog. After that every call fails with `context is blocked by an
  open confirm dialog` until something dismisses it. vibium serves one request
  at a time and ignores `notifications/cancelled`, so nothing can clear the
  dialog while the click is still waiting. A `data-confirm` link locked a QA
  agent's turn this way (issue fea9aba9).

  So after a call fails, this asks the browser whether a dialog is open and
  dismisses it. Dismissing a confirm means its action does not happen, which is
  the safe default. vibium reports the dialog's type but not its text, so the
  note gives only the type.

  If the call timed out, the server stopped waiting at the same deadline and
  nobody reads this answer. The note is then left with the copy's
  `CmsHarness.Browser.Owner`, and the next call's answer carries it.
  """

  require Logger

  alias CmsHarness.Browser.Owner
  alias CmsHarness.Mcp.Transport

  # vibium's own limit on a click that opened a dialog, plus a margin. A probe
  # sent after the caller's deadline waits behind that click.
  @probe_timeout_ms 65_000

  @blocked ~r/blocked by an open (\w+) dialog/

  @doc "Dismiss a dialog the failed call left open, and note it on the answer."
  @spec recover({:ok, String.t()} | {:error, term()}, GenServer.name(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def recover({:ok, _text} = result, _client, _root), do: result

  def recover({:error, _reason} = result, client, root) do
    case dismiss_open(client) do
      nil ->
        result

      type ->
        Logger.warning("[CmsHarness] dismissed a native #{type} dialog in #{root}'s browser")
        deliver(result, type, root)
    end
  end

  @doc "Append notes to an answer, after a blank line."
  @spec annotate({:ok, String.t()} | {:error, term()}, [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def annotate(result, []), do: result
  def annotate({:ok, text}, notes), do: {:ok, join(text, notes)}
  def annotate({:error, reason}, notes), do: {:error, join(reason, notes)}

  defp dismiss_open(client) do
    with {:error, text} when is_binary(text) <- probe(client, "browser_get_url"),
         [_, type] <- Regex.run(@blocked, text),
         {:ok, _dismissed} <- probe(client, "browser_dialog_dismiss") do
      type
    else
      _no_dialog -> nil
    end
  end

  defp probe(client, tool),
    do: Transport.impl().call(client, tool, %{}, timeout: @probe_timeout_ms)

  defp deliver({:error, %{reason: :request_timeout}} = result, type, root) do
    Owner.leave_note(root, note(type, :earlier))
    result
  end

  defp deliver(result, type, _root), do: annotate(result, [note(type, :this)])

  defp note(type, :this) do
    "dialog dismissed: #{type}. This call opened a native #{type} dialog. It was " <>
      "cancelled, so the action behind it did not happen. The browser does not report " <>
      "a dialog's text."
  end

  defp note(type, :earlier) do
    "dialog dismissed: #{type}. An earlier call that timed out opened a native #{type} " <>
      "dialog. It was cancelled, so the action behind it did not happen. The browser " <>
      "does not report a dialog's text."
  end

  defp join(text, notes) when is_binary(text), do: Enum.join([text | notes], "\n\n")
  defp join(reason, notes), do: reason |> inspect() |> join(notes)
end

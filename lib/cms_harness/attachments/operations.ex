defmodule CmsHarness.Attachments.Operations do
  @moduledoc """
  Runs one of the agents' own tools (`CoreTools`) in an attached copy.

  Main's attachment is a transport, not a second toolset: the call reaches
  the same module a coder in that copy would run, with the context that copy's
  agents get, so output spills, `mix test` is routed through the copy's
  analysis service, and paths resolve the same way (issue 2394520b).
  """

  alias CmsHarness.Agents.CoreTools
  alias CmsHarness.Agents.Engine.Impl

  @spec execute(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(root, %{"tool" => name, "input" => input} = payload) when is_map(input) do
    case CoreTools.fetch(name) do
      {:ok, module} ->
        module.execute(input, context(root, payload))

      :error ->
        {:error,
         "Unknown tool #{inspect(name)}; use one of #{Enum.join(CoreTools.names(), ", ")}."}
    end
  end

  def execute(_root, _payload),
    do: {:error, "An attachment call names a tool and its input."}

  # What the engine gives an agent working in this copy, scoped to the
  # attachment: its own spill directory, nothing of the agent's scratch.
  defp context(root, payload) do
    spill = Impl.spill_dir("attachment-" <> to_string(payload["attachment_id"]))

    %{
      working_directory: root,
      allowed_paths: [root, spill],
      bash_restricted: true,
      working_copy_id: payload["working_copy_id"],
      spill_dir: spill
    }
  end
end

defmodule CodeMySpec.Chat.ToolRegistry do
  @moduledoc """
  The tools a conversation may call, as `ReqLLM.Tool` structs.

  A seam rather than a list so the runner can be driven with no tools at all
  in tests that are about the loop rather than the tools.
  """

  alias CodeMySpec.Conversations.Conversation

  @callback list_tools(Conversation.t()) :: [ReqLLM.Tool.t()]
end

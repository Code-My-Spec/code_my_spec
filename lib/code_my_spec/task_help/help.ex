defmodule CodeMySpec.TaskHelp.Help do
  @moduledoc """
  Curated help for a single agent task type: the markdown body shown in
  the agent progress view plus an optional `video_url` drawn from the
  content document's `.yaml` sidecar.

  Only constructed when a curated document exists for the task type;
  `nil` `video_url` means the document carried no video.
  """

  @enforce_keys [:task_type, :body]
  defstruct [:task_type, :body, :video_url]

  @type t :: %__MODULE__{
          task_type: module(),
          body: String.t(),
          video_url: String.t() | nil
        }
end

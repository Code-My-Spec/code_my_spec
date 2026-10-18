defmodule CodeMySpec.Agents.Tools.EpicsResponses do
  @moduledoc """
  How the epic readings are written out for the main agent.

  Titles rather than ids, for the reason criterion 3271 gives about tasks: an id
  is a second lookup wearing the costume of an answer, and the agent that asked
  this question asked it in order to say something to somebody.
  """

  @spec orphans([map()]) :: CodeMySpec.Tools.Tool.result()
  def orphans([]) do
    {:ok, "Every ready story on this project belongs to an epic."}
  end

  def orphans(stories) do
    {:ok,
     """
     #{length(stories)} ready story(s) belong to no epic:

     #{Enum.map_join(stories, "\n", &"  Story #{&1.number}: #{&1.title}")}
     """}
  end

  @spec error(term()) :: CodeMySpec.Tools.Tool.result()
  def error(reason) do
    {:error, "Could not read the epics: #{inspect(reason)}"}
  end
end

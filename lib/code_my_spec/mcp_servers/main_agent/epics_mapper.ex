defmodule CodeMySpec.McpServers.MainAgent.EpicsMapper do
  @moduledoc """
  How the epic readings are written out for the main agent.

  Titles rather than ids, for the reason criterion 3271 gives about tasks: an id
  is a second lookup wearing the costume of an answer, and the agent that asked
  this question asked it in order to say something to somebody.
  """

  alias Anubis.Server.Response

  @spec orphans([map()]) :: Response.t()
  def orphans([]) do
    Response.tool()
    |> Response.text("Every ready story on this project belongs to an epic.")
  end

  def orphans(stories) do
    Response.tool()
    |> Response.text("""
    #{length(stories)} ready story(s) belong to no epic:

    #{Enum.map_join(stories, "\n", &"  #{&1.title} (#{&1.id})")}
    """)
  end

  @spec error(term()) :: Response.t()
  def error(reason) do
    Response.tool() |> Response.error("Could not read the epics: #{inspect(reason)}")
  end
end

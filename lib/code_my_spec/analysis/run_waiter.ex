defmodule CodeMySpec.Analysis.RunWaiter do
  @moduledoc """
  An agent waiting on a run somebody else started (e.g. a promotion that found
  one already running at its commit). Answered when the run lands, as its
  requester is.
  """
  use Ecto.Schema

  @primary_key false
  schema "analysis_run_waiters" do
    belongs_to :run, CodeMySpec.Analysis.Run
    field :agent_id, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

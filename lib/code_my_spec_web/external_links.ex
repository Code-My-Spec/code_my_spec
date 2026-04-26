defmodule CodeMySpecWeb.ExternalLinks do
  @moduledoc """
  Single source of truth for outbound URLs used across pages, LiveViews and
  controllers. Update once here when a handle or domain changes.
  """

  @cal_john "https://cal.com/john-s10-davenport"

  @doc "Cal.com booking link for John Davenport (\"Talk to John\")."
  def cal_john, do: @cal_john
end

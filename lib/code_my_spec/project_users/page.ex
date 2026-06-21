defmodule CodeMySpec.ProjectUsers.Page do
  @moduledoc """
  One page of registered users read from a target application, with the
  pagination metadata the endpoint reports.
  """

  alias CodeMySpec.ProjectUsers.User

  @enforce_keys [:users, :page, :page_size, :total]
  defstruct [:users, :page, :page_size, :total]

  @type t :: %__MODULE__{
          users: [User.t()],
          page: pos_integer(),
          page_size: pos_integer(),
          total: non_neg_integer()
        }
end

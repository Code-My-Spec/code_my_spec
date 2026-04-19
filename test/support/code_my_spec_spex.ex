defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpecSpex.Fixtures, CodeMySpecWeb, CodeMySpecLocalWeb]
end

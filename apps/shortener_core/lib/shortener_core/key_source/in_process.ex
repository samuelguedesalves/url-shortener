defmodule ShortenerCore.KeySource.InProcess do
  @moduledoc """
  Random 7-character base62 codes generated in the calling process.

  Early-milestone stand-in for KGS (ADR 0001). It is NOT collision-free: uniqueness comes
  from the `INSERT ... IF NOT EXISTS` claim in the write path.
  """

  @behaviour ShortenerCore.KeySource

  alias ShortenerCore.Base62

  @code_length 7

  @impl true
  def next_key, do: {:ok, Base62.random(@code_length)}
end

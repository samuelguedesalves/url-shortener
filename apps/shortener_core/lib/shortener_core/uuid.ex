defmodule ShortenerCore.Uuid do
  @moduledoc """
  Random (version 4) UUIDs in the canonical lowercase text form, the form Xandra reads and
  writes for Cassandra `uuid` columns.
  """

  @spec generate() :: String.t()
  def generate do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [<<a::32>>, <<b::16>>, <<4::4, c::12>>, <<2::2, d::14>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end

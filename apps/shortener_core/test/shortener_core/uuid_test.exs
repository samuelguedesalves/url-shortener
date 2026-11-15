defmodule ShortenerCore.UuidTest do
  use ExUnit.Case, async: true

  alias ShortenerCore.Uuid

  test "generate returns a canonical lowercase version 4 UUID" do
    assert Uuid.generate() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "generate returns a different value every call" do
    uuids = for _ <- 1..1_000, do: Uuid.generate()
    assert length(Enum.uniq(uuids)) == 1_000
  end
end

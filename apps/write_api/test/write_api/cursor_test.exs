defmodule WriteApi.CursorTest do
  use ExUnit.Case, async: true

  alias WriteApi.Cursor

  test "round-trips a created_at and a code" do
    created_at = ~U[2026-11-09 10:00:00.123Z]

    assert {:ok, {^created_at, "abc1234"}} =
             created_at |> Cursor.encode("abc1234") |> Cursor.decode()
  end

  test "encodes url-safe base64 without padding of <unix_ms>:<code>" do
    created_at = ~U[2026-11-09 10:00:00.123Z]

    expected =
      Base.url_encode64("#{DateTime.to_unix(created_at, :millisecond)}:abc1234", padding: false)

    assert Cursor.encode(created_at, "abc1234") == expected
  end

  test "rejects malformed cursors" do
    assert Cursor.decode("%%%") == :error
    assert Cursor.decode("") == :error
    assert Cursor.decode(Base.url_encode64("abc", padding: false)) == :error
    assert Cursor.decode(Base.url_encode64("1:../x", padding: false)) == :error
    assert Cursor.decode(Base.url_encode64("x:abc1234", padding: false)) == :error
    assert Cursor.decode(Base.url_encode64("1:ab", padding: false)) == :error

    assert Cursor.decode(Base.url_encode64("1:" <> String.duplicate("a", 33), padding: false)) ==
             :error
  end

  test "rejects non-binary input" do
    assert Cursor.decode(nil) == :error
  end
end

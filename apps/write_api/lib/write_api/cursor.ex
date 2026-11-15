defmodule WriteApi.Cursor do
  @moduledoc """
  Opaque pagination cursor for the link listing: url-safe base64, no padding, of
  `"<unix_ms>:<code>"`. Milliseconds because Cassandra stores timestamps at that precision.
  """

  @code ~r/\A[0-9A-Za-z_-]{3,32}\z/
  @millis ~r/\A\d{1,15}\z/

  @spec encode(DateTime.t(), String.t()) :: String.t()
  def encode(%DateTime{} = created_at, code) when is_binary(code) do
    Base.url_encode64("#{DateTime.to_unix(created_at, :millisecond)}:#{code}", padding: false)
  end

  @spec decode(term()) :: {:ok, {DateTime.t(), String.t()}} | :error
  def decode(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [millis, code] <- String.split(raw, ":", parts: 2),
         true <- Regex.match?(@millis, millis),
         true <- Regex.match?(@code, code),
         {:ok, created_at} <- DateTime.from_unix(String.to_integer(millis), :millisecond) do
      {:ok, {created_at, code}}
    else
      _ -> :error
    end
  end

  def decode(_cursor), do: :error
end

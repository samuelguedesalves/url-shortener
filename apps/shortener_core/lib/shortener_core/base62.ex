defmodule ShortenerCore.Base62 do
  @moduledoc """
  Base62 encoding and random code generation.

  The alphabet is `0-9`, `A-Z`, `a-z`.
  """

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @base 62

  # Bytes below this limit map to the alphabet without modulo bias (62 * 4 = 248).
  @unbiased_limit 248

  @doc "Encodes a non-negative integer as a base62 string."
  @spec encode(non_neg_integer()) :: String.t()
  def encode(0), do: "0"

  def encode(n) when is_integer(n) and n > 0 do
    n |> do_encode([]) |> List.to_string()
  end

  defp do_encode(0, acc), do: acc
  defp do_encode(n, acc), do: do_encode(div(n, @base), [Enum.at(@alphabet, rem(n, @base)) | acc])

  @doc "Decodes a base62 string. Returns `:error` for an empty string or an invalid character."
  @spec decode(String.t()) :: {:ok, non_neg_integer()} | :error
  def decode(""), do: :error

  def decode(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, 0}, fn char, {:ok, acc} ->
      case Enum.find_index(@alphabet, &(&1 == char)) do
        nil -> {:halt, :error}
        index -> {:cont, {:ok, acc * @base + index}}
      end
    end)
  end

  @doc "Returns a cryptographically random base62 string of exactly `length` characters."
  @spec random(pos_integer()) :: String.t()
  def random(length) when is_integer(length) and length > 0 do
    length |> take_chars([]) |> List.to_string()
  end

  defp take_chars(0, acc), do: acc

  defp take_chars(remaining, acc) do
    # Over-request bytes so one round almost always fills the code.
    bytes = :crypto.strong_rand_bytes(remaining * 2)

    {chars, left} =
      for <<byte <- bytes>>, byte < @unbiased_limit, reduce: {acc, remaining} do
        {chars, left} when left > 0 -> {[Enum.at(@alphabet, rem(byte, @base)) | chars], left - 1}
        {chars, 0} -> {chars, 0}
      end

    take_chars(left, chars)
  end
end

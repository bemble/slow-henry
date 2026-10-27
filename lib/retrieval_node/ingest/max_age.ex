defmodule RetrievalNode.Ingest.MaxAge do
  @moduledoc """
  The `max_age` of a git source's non-code data (`max_age = "2y"` in
  sources.toml): a number followed by `d`, `w`, `m` or `y` — days, weeks,
  months, years. Data older than the cutoff it gives (today minus the age,
  at midnight UTC) is neither indexed nor kept.
  """

  @format ~r/\A([1-9][0-9]{0,3})([dwmy])\z/
  @units %{"d" => :day, "w" => :week, "m" => :month, "y" => :year}

  @doc "Whether `value` is a valid `max_age`."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_binary(value) and Regex.match?(@format, value)

  @doc """
  The cutoff of a source config's `max_age` on `today`, as an ISO 8601
  UTC timestamp (the format GitHub returns, so the two compare as strings),
  or nil without one.
  """
  @spec cutoff(map() | nil, Date.t()) :: String.t() | nil
  def cutoff(config, today \\ Date.utc_today())

  def cutoff(%{"max_age" => value}, today) when is_binary(value) do
    case Regex.run(@format, value) do
      [_, n, unit] ->
        date = Date.shift(today, [{@units[unit], -String.to_integer(n)}])
        Date.to_iso8601(date) <> "T00:00:00Z"

      nil ->
        nil
    end
  end

  def cutoff(_config, _today), do: nil
end

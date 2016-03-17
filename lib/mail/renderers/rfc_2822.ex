defmodule Mail.Renderers.RFC2822 do
  import Mail.Message, only: [match_content_type?: 2]

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @moduledoc """
  RFC2822 Parser

  Will attempt to render a valid RFC2822 message
  from a `%Mail.Message{}` data model.

      Mail.Renderers.RFC2822.render(message)
  """

  @blacklisted_headers [:bcc]
  @address_types ["from", "to", "cc", "bcc"]

  @doc """
  Renders a message according to the RFC2882 spec
  """
  def render(%Mail.Message{multipart: true} = message) do
    message = reorganize(message)
    headers = put_in(message.headers, [:mime_version], "1.0")

    Map.put(message, :headers, headers)
    |> render_part()
  end

  def render(%Mail.Message{} = message) do
    render_part(message)
  end

  @doc """
  Render an individual part

  An optional function can be passed used during the rendering of each
  individual part
  """
  def render_part(message, render_part_function \\ &render_part/1)
  def render_part(%Mail.Message{multipart: true} = message, fun) do
    boundary = Mail.Message.get_boundary(message)
    message = Mail.Message.put_boundary(message, boundary)

    headers = render_headers(message.headers, @blacklisted_headers)
    boundary = "--#{boundary}"

    parts =
      render_parts(message.parts, fun)
      |> Enum.join("\r\n\r\n#{boundary}\r\n")

    "#{headers}\r\n\r\n#{boundary}\r\n#{parts}\r\n#{boundary}--"
  end
  def render_part(%Mail.Message{} = message, _fun) do
    encoded_body = encode(message.body, message)
    "#{render_headers(message.headers, @blacklisted_headers)}\r\n\r\n#{encoded_body}"
  end

  def render_parts(parts, fun \\ &render_part/1) when is_list(parts),
    do: Enum.map(parts, &fun.(&1))

  @doc """
  Will render a given header according to the RFC2882 spec
  """
  def render_header(key, value)
  def render_header(key, value) when is_atom(key),
    do: render_header(Atom.to_string(key), value)
  def render_header(key, value) do
    String.split(key, "_")
    |> Enum.map(&String.capitalize(&1))
    |> Enum.join("-")
    |> Kernel.<>(": ")
    |> Kernel.<>(render_header_value(key, value))
  end

  defp render_header_value(address_type, addresses) when is_list(addresses) and address_type in @address_types,
    do: Enum.map(addresses, &render_address(&1))
        |> Enum.join(", ")
  defp render_header_value(address_type, address) when address_type in @address_types,
    do: render_address(address)
  defp render_header_value("content_transfer_encoding" = key, value) when is_atom(value) do
    value =
      value
      |> Atom.to_string()
      |> String.replace("_", "-")

    render_header_value(key, value)
  end

  defp render_header_value(_key, [value | subtypes]),
    do: Enum.join([value | render_subtypes(subtypes)], "; ")
  defp render_header_value(key, value),
    do: render_header_value(key, List.wrap(value))

  defp render_address({name, email}), do: ~s("#{name}" <#{email}>)
  defp render_address(email), do: email
  defp render_subtypes([]), do: []
  defp render_subtypes([{key, value} | subtypes]) when is_atom(key),
    do: render_subtypes([{Atom.to_string(key), value} | subtypes])

  defp render_subtypes([{"boundary", value} | subtypes]) do
    [~s(boundary="#{value}") | render_subtypes(subtypes)]
  end
  defp render_subtypes([{key, value} | subtypes]) do
    key = String.replace(key, "_", "-")
    ["#{key}=#{value}" | render_subtypes(subtypes)]
  end

  @doc """
  Will render all headers according to the RFC2882 spec

  Can take an optional list of headers to blacklist
  """
  def render_headers(headers, blacklist \\ [])
  def render_headers(map, blacklist) when is_map(map),
    do: Map.to_list(map)
        |> render_headers(blacklist)
  def render_headers(list, blacklist) when is_list(list) do
    Enum.reject(list, &(Enum.member?(blacklist, elem(&1, 0))))
    |> do_render_headers()
    |> Enum.reverse()
    |> Enum.join("\r\n")
  end

  @doc """
  Builds a RFC2822 timestamp from an Erlang timestamp

  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)

  This function always assumes the Erlang timestamp is in Universal time, not Local time
  """
  def timestamp_from_erl({{year, month, day} = date, {hour, minute, second} = time}) do
    day_name = Enum.at(@days, :calendar.day_of_the_week(date) - 1)
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " +0000"
  end

  defp pad(num),
    do: num
        |> Integer.to_string()
        |> String.rjust(2, ?0)

  defp do_render_headers([]), do: []
  defp do_render_headers([{key, value} | headers]) do
    [render_header(key, value) | do_render_headers(headers)]
  end

  defp reorganize(%Mail.Message{multipart: true} = message) do
    content_type = Mail.Message.get_content_type(message)

    if Mail.Message.has_attachment?(message) do
      text_parts =
        Enum.filter(message.parts, &(match_content_type?(&1, ~r/text\/(plain|html)/)))
        |> Enum.sort(&(&1 > &2))

      content_type = List.replace_at(content_type, 0, "multipart/mixed")
      message = Mail.Message.put_content_type(message, content_type)

      if Enum.any?(text_parts) do
        message = Enum.reduce(text_parts, message, &(Mail.Message.delete_part(&2, &1)))
        mixed_part =
          Mail.build_multipart()
          |> Mail.Message.put_content_type("multipart/alternative")

        mixed_part = Enum.reduce(text_parts, mixed_part, &(Mail.Message.put_part(&2, &1)))
        put_in(message.parts, List.insert_at(message.parts, 0, mixed_part))
      end
    else
      content_type = List.replace_at(content_type, 0, "multipart/alternative")
      Mail.Message.put_content_type(message, content_type)
    end
  end
  defp reorganize(%Mail.Message{} = message), do: message

  defp encode(body, message) do
    Mail.Encoder.encode(body, get_in(message.headers, [:content_transfer_encoding]))
  end
end

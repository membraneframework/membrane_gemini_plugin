defmodule Membrane.Gemini.ResponseStartEvent do
  @moduledoc """
  Sent by `Membrane.Gemini.Endpoint` when it starts receiving a new response.
  """

  @derive Membrane.EventProtocol

  defstruct []
end

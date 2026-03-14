defmodule Membrane.Gemini.Events.ResponseEnd do
  @moduledoc """
  Sent by `Membrane.Gemini.Bin` upon model turn completion or interruption.
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
          #  Whether or not the turn was interrupted by the user
          interrupted?: boolean()
        }

  @enforce_keys [:interrupted?]

  defstruct @enforce_keys
end

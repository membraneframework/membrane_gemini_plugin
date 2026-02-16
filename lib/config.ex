defmodule Membrane.Gemini.Config do
  @moduledoc """
  Options for configuring the Gemini Live API session.
  These get passed to `Gemini.Live.Session.start_link/1` internally.
  """

  @type t :: %__MODULE__{
          # The handle to use to resume previous conversations, updated and sent by the server on subsequent turns.
          resume_handle: nil | String.t(),
          # The strategy to use for context compression, for details see `Gemini.Types.Live.ContextWindowCompression`.
          context_window_compression:
            nil
            | %{
                required(:sliding_window) => %{optional(:target_tokens) => integer()},
                optional(:trigger_tokens) => integer()
              },
          # The system instruction that will be attached to each prompt for the model to follow.
          system_instruction: nil | binary(),
          # Configures realtime input behaviour, e.g. automatic user activity detection.
          # For details, see `Gemini.Types.Live.RealtimeInputConfig`.
          # NOTE: `:activity_handling` is locked to `:start_of_activity_interrupts` (barge-in),
          # NOTE: due to how the Membrane element is implemented
          realtime_input_config:
            nil
            | %{
                optional(:automatic_activity_detection) =>
                  nil
                  | %{
                      optional(:disabled) => boolean(),
                      optional(:start_of_speech_sensitivity) => :low | :high,
                      optional(:end_of_speech_sensitivity) => :low | :high,
                      optional(:prefix_padding_ms) => integer(),
                      optional(:silence_duration_ms) => integer()
                    }
              },
          # Name of the model that should be used.
          # For details, see `Gemini.Live.Models`.
          model: String.t(),
          # The API to use. For now, only Gemini Live API is supported via `:gemini` (default).
          auth: :gemini,
          # The API version to use. Accepts `v1beta` (default) and `v1alpha`.
          # `v1alpha` might be needed for newer features.
          api_version: String.t(),
          # Set to any map to enable user voice activity transcription (default). Set to `nil` to disable.
          input_audio_transcription: nil | %{},
          # Set to any map to enable model response transcription (default). Set to `nil` to disable.
          output_audio_transcription: nil | %{},
          # Set to any map to enable session resumption (default). Set to `nil` to disable.
          # NOTE: Sessions need at least one user interaction, be it text or audio,
          # NOTE: to send back a proper resumption handle.
          session_resumption: nil | map(),
          # Configuration for content generation parameters.
          # For more details, see `Gemini.Types.GenerationConfig`.
          generation_config:
            nil
            | %{
                optional(:candidate_count) => nil | integer(),
                optional(:frequency_penalty) => nil | float(),
                optional(:logprobs) => nil | integer(),
                optional(:max_output_tokens) => nil | integer(),
                optional(:presence_penalty) => nil | float(),
                optional(:property_ordering) => nil | [String.t()],
                optional(:response_json_schema) => nil | map(),
                optional(:response_logprobs) => nil | boolean(),
                optional(:response_mime_type) => nil | String.t(),
                optional(:response_modalities) => nil | [String.t() | :audio | :text],
                optional(:response_schema) => nil | map(),
                optional(:seed) => nil | integer(),
                optional(:speech_config) =>
                  nil
                  | %{
                      optional(:language_code) => nil | String.t(),
                      optional(:voice_config) =>
                        nil
                        | %{
                            optional(:prebuilt_voice_config) =>
                              nil
                              | %{
                                  optional(:voice_name) => nil | String.t()
                                }
                          }
                    },
                optional(:stop_sequences) => nil | [String.t()],
                optional(:temperature) => nil | float(),
                optional(:thinking_config) =>
                  nil
                  | %{
                      optional(:include_thoughts) => nil | boolean(),
                      optional(:thinking_budget) => nil | integer(),
                      optional(:thinking_level) => nil | :minimal | :low | :medium | :high
                    },
                optional(:top_k) => nil | integer(),
                optional(:top_p) => nil | float()
              },
          extra_opts: Keyword.t()
        }

  defstruct [
    :resume_handle,
    :context_window_compression,
    :system_instruction,
    :realtime_input_config,
    model: "gemini-2.5-flash-native-audio-latest",
    auth: :gemini,
    api_version: "v1beta",
    input_audio_transcription: %{},
    output_audio_transcription: %{},
    session_resumption: %{},
    generation_config: %{
      response_modalities: [:audio]
    },
    extra_opts: []
  ]
end

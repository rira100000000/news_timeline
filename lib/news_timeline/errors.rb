# frozen_string_literal: true

module NewsTimeline
  class Error < StandardError; end

  # 生成パイプラインの途中で発生した回復不能なエラー
  class GenerationError < Error; end

  # Gemini API側の一時的な障害（時間をおけば回復する可能性がある）
  class ServiceUnavailableError < GenerationError; end

  # Phase 0の事前検証で入力が不適切と判定された
  class ValidationError < Error
    attr_reader :error_type, :suggestions

    def initialize(message, error_type: nil, suggestions: [])
      super(message)
      @error_type = error_type
      @suggestions = suggestions
    end
  end
end

# frozen_string_literal: true

module NewsTimeline
  # gem同梱のプロンプトテンプレートを読み込み、{プレースホルダ}を置換する。
  # prompt_dir を指定すると同名ファイルで差し替えられる。
  class PromptStore
    DEFAULT_DIR = File.expand_path("prompts", __dir__)

    def initialize(dir = nil)
      @dir = dir || DEFAULT_DIR
    end

    def render(name, vars = {})
      vars.reduce(read(name)) do |text, (key, value)|
        text.gsub("{#{key}}", value.to_s)
      end
    end

    def read(name)
      path = File.join(@dir, "#{name}.md")
      raise GenerationError, "プロンプトテンプレートが見つかりません: #{path}" unless File.exist?(path)

      File.read(path)
    end
  end
end

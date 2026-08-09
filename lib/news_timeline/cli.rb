# frozen_string_literal: true

require "optparse"
require "json"
require "logger"
require "fileutils"

module NewsTimeline
  # news-timeline コマンドの本体。
  #   news-timeline <URL> "<追いたい話題>" [--model MODEL] [--output-dir DIR]
  class CLI
    API_KEY_GUIDE_URL = "https://aistudio.google.com/apikey"

    def self.start(argv)
      new.run(argv)
    end

    def run(argv)
      options = { output_dir: "." }
      parser = build_parser(options)
      args = parser.parse(argv)

      return 0 if options[:help]
      return usage_error(parser) unless args.size == 2

      api_key = ENV.fetch("GEMINI_API_KEY", nil)
      return api_key_error if api_key.nil? || api_key.empty?

      url, user_intent = args
      generate(api_key, url, user_intent, options)
    rescue OptionParser::ParseError => e
      warn "エラー: #{e.message}"
      1
    end

    private

    def build_parser(options)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: news-timeline <URL> "<追いたい話題>" [options]

          ニュース記事のURLと追いたい話題から、経緯をまとめたタイムラインを生成します。
          カレントディレクトリ（または --output-dir）に timeline.json と report.md を出力します。
        BANNER
        opts.on("--model MODEL", "使用するGeminiモデル（デフォルト: #{Generator::DEFAULT_MODEL}）") do |v|
          options[:model] = v
        end
        opts.on("--output-dir DIR", "出力先ディレクトリ（デフォルト: カレントディレクトリ）") do |v|
          options[:output_dir] = v
        end
        opts.on("-h", "--help", "このヘルプを表示") do
          puts opts
          options[:help] = true
        end
      end
    end

    def generate(api_key, url, user_intent, options)
      logger = Logger.new($stdout, level: :info)
      logger.formatter = ->(severity, _time, _progname, msg) { severity == "INFO" ? "#{msg}\n" : "[#{severity}] #{msg}\n" }

      generator = Generator.new(api_key: api_key, model: options[:model], logger: logger)

      logger.info "タイムラインを生成します（数分かかります）"
      result = generator.generate(url: url, user_intent: user_intent)

      write_outputs(result, url, user_intent, options[:output_dir], logger)
      0
    rescue ValidationError => e
      warn "入力チェックで中断しました。"
      warn e.message
      if e.suggestions.any?
        warn "たとえば、次のような観点なら時系列にできます:"
        e.suggestions.each { |s| warn "  - #{s}" }
      end
      1
    rescue Error => e
      warn "エラー: #{e.message}"
      1
    end

    def write_outputs(result, url, user_intent, output_dir, logger)
      FileUtils.mkdir_p(output_dir)
      json_path = File.join(output_dir, "timeline.json")
      report_path = File.join(output_dir, "report.md")

      File.write(json_path, "#{JSON.pretty_generate(result)}\n")
      File.write(report_path, Report.render(result, source_url: url, user_intent: user_intent))

      logger.info ""
      logger.info "生成が完了しました（ブロック数: #{result[:blocks].size}）:"
      logger.info "  #{json_path}"
      logger.info "  #{report_path}"
    end

    def usage_error(parser)
      warn "エラー: 引数は <URL> と \"<追いたい話題>\" の2つが必要です。"
      warn ""
      warn parser
      1
    end

    def api_key_error
      warn "GEMINI_API_KEY が設定されていません。"
      warn "APIキーは #{API_KEY_GUIDE_URL} で無料で取得できます。取得後、以下を実行してください:"
      warn ""
      warn "  export GEMINI_API_KEY=あなたのAPIキー"
      1
    end
  end
end

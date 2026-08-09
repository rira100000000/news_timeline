# frozen_string_literal: true

require "gemini"
require "net/http"
require "uri"
require "json"
require "timeout"
require "logger"
require "date"

module NewsTimeline
  # ニュース記事URLとユーザー意図から、多段フェーズ処理でタイムラインを生成する。
  #
  #   Phase 0   入力妥当性のLLM判定（例外時はvalid扱いのフェイルセーフ）
  #   Phase 1   検索戦略の立案
  #   Phase 2   Google検索グラウンディング付き深掘りリサーチ
  #   Phase 2.5 グラウンディング引用URL（リダイレクト）の実URL解決
  #   Phase 3   レポートをタイムラインJSONに構造化
  #   Phase 3.5 網羅性チェックと不足ブロックの追加
  class Generator
    DEFAULT_MODEL = "gemini-2.5-flash"
    # Phase 2はグラウンディング検索の安定動作を確認済みのモデルに固定する
    PHASE2_MODEL = "gemini-2.5-flash"
    GEMINI_TIMEOUT_SECONDS = 180
    ARTICLE_MAX_CHARS = 5000

    def initialize(api_key:, model: nil, logger: nil, prompt_dir: nil, transcript_path: nil)
      @api_key = api_key
      @model = model || ENV["GEMINI_MODEL"] || DEFAULT_MODEL
      @logger = logger || Logger.new($stdout, level: :info)
      @prompts = PromptStore.new(prompt_dir)
      @transcript_path = transcript_path
      @transcript = +""

      raise Error, "Gemini APIキーが設定されていません" if @api_key.nil? || @api_key.empty?
    end

    # タイムラインを生成して返す。
    # 戻り値: { title:, description:, blocks: [{ event_year:, event_month:, event_day:,
    #           title:, content:, evidence_source_urls:, position: }, ...] }
    def generate(url:, user_intent:)
      transcript_header(url, user_intent)

      client = Gemini::Client.new(@api_key)
      today = Date.today.strftime("%Y年%-m月%-d日")
      news_context = @prompts.render("news_context", "今日の日付" => today)

      @logger.info "元記事を取得しています: #{url}"
      article_content = measure_time("Fetch Article Content") { fetch_url_content(url) }
      raise GenerationError, "元記事の取得に失敗しました。URLを確認してください。" if article_content.nil?

      transcript "## Article Content (First 500 chars)"
      transcript "#{article_content[0, 500]}..."

      @logger.info "Phase 0: 入力の事前検証"
      validation = measure_time("Phase 0") { validate_input(client, article_content, user_intent) }
      unless validation[:valid]
        raise ValidationError.new(validation[:error_message],
                                  error_type: validation[:error_type],
                                  suggestions: validation[:suggestions] || [])
      end

      @logger.info "Phase 1: 検索戦略の立案"
      phase1_result = measure_time("Phase 1") do
        execute_phase1(client, url, user_intent, article_content, news_context)
      end

      @logger.info "Phase 2: Google検索グラウンディングによる深掘りリサーチ"
      phase2_response = measure_time("Phase 2") do
        execute_phase2(client, phase1_result, url, article_content, today)
      end
      phase2_result = phase2_response.text

      @logger.info "Phase 2.5: グラウンディング検索URLの解決"
      verified_urls = measure_time("Phase 2.5") { extract_and_resolve_grounding_urls(phase2_response) }

      @logger.info "Phase 3: タイムラインJSONへの構造化"
      phase3_result = measure_time("Phase 3") do
        execute_phase3(client, phase2_result, verified_urls, news_context)
      end

      @logger.info "Phase 3.5: 網羅性チェックと不足ブロックの追加"
      phase3_5_result = measure_time("Phase 3.5") do
        execute_phase3_5(client, phase2_result, phase3_result, verified_urls, news_context)
      end

      result = OutputFormatter.format(phase3_5_result, logger: @logger)
      transcript "## Final Result"
      transcript JSON.pretty_generate(result)
      result
    rescue ValidationError, GenerationError
      raise
    rescue StandardError => e
      transcript "## Error Occurred"
      transcript "#{e.class}: #{e.message}"
      raise GenerationError, "タイムライン生成に失敗しました: #{e.message}"
    ensure
      write_transcript
    end

    private

    # Phase 0: 元記事とユーザー意図の関連性、タイムライン化可能性を評価する。
    # LLM呼び出しが失敗した場合は検証をスキップして続行する（フェイルセーフ）。
    def validate_input(client, article_content, user_intent)
      prompt = @prompts.render("phase0",
                               "元記事の内容" => article_content[0, 3000],
                               "ユーザーの意図" => user_intent)

      response = client.generate_content(
        prompt,
        model: @model,
        response_mime_type: "application/json",
        response_schema: phase0_response_schema
      )
      result = JSON.parse(response.text, symbolize_names: true)
      transcript "Phase 0 result: #{result.inspect}"

      if result[:content_appropriate] == "不適切"
        return { valid: false, error_type: :inappropriate_content,
                 error_message: inappropriate_content_message(result),
                 suggestions: result[:suggestions] || [] }
      end

      if result[:timelineable] == "不可能"
        return { valid: false, error_type: :not_timelineable,
                 error_message: not_timelineable_message(result),
                 suggestions: result[:suggestions] || [] }
      end

      @logger.warn "Phase 0: 元記事との関連性が#{result[:relevance]}ため、ユーザー意図を優先します（#{result[:relevance_reason]}）" if %w[低い なし].include?(result[:relevance])

      { valid: true }
    rescue StandardError => e
      @logger.warn "Phase 0でエラーが発生したため、検証をスキップして続行します: #{e.message}"
      { valid: true }
    end

    # 元記事を取得し、タグを除去したテキストを返す（取得失敗時はnil）
    def fetch_url_content(url)
      uri = URI.parse(url)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 10, read_timeout: 30) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = UrlResolver::USER_AGENT
        http.request(request)
      end

      return nil unless response.code == "200"

      text = response.body.dup.force_encoding("UTF-8").scrub
                     .gsub(%r{<script.*?</script>}m, "")
                     .gsub(%r{<style.*?</style>}m, "")
                     .gsub(/<.*?>/m, " ")
                     .gsub(/\s+/, " ")
                     .strip

      text = "#{text[0, ARTICLE_MAX_CHARS]}\n\n（以下省略）" if text.length > ARTICLE_MAX_CHARS
      text
    rescue StandardError => e
      @logger.error "元記事の取得中にエラー: #{e.message}"
      nil
    end

    def call_gemini(client, prompt, response_schema: nil, google_search: false, model: nil)
      current_model = model || @model
      transcript "### Call Gemini (Model: #{current_model})"
      transcript "Google Search: #{google_search}"
      transcript "Schema: #{response_schema.inspect}" if response_schema
      transcript "#### Prompt"
      transcript prompt
      transcript "-" * 20

      options = { model: current_model }
      options[:google_search] = google_search if google_search
      if response_schema
        options[:response_mime_type] = "application/json"
        options[:response_schema] = response_schema
      end

      response = nil
      Timeout.timeout(GEMINI_TIMEOUT_SECONDS) do
        response = client.generate_content(prompt, **options)
      end

      raise GenerationError, "Gemini APIの呼び出しに失敗しました" unless response.valid?

      transcript "#### Response"
      transcript response.text
      transcript "-" * 20
      response
    rescue Net::ReadTimeout, Net::OpenTimeout
      raise GenerationError, "Gemini APIとの通信でタイムアウトが発生しました"
    rescue Timeout::Error
      raise GenerationError, "Gemini APIの呼び出しがタイムアウトしました（#{GEMINI_TIMEOUT_SECONDS}秒経過）"
    rescue Faraday::ServerError
      raise ServiceUnavailableError, "AI生成サービスが一時的に利用できません。しばらく時間をおいてから再度お試しください。"
    end

    def execute_phase1(client, url, user_intent, article_content, news_context)
      template = @prompts.render("phase1",
                                 "元記事のURL" => url,
                                 "ユーザの入力" => user_intent)
      prompt = template + "\n\n---\n\n【元記事の内容】\n#{article_content}\n\n---" + news_context

      call_gemini(client, prompt).text
    end

    # ハルシネーション対策の前提文（news_context）は、グラウンディング検索を
    # 抑制しないようPhase 2には意図的に注入しない
    def execute_phase2(client, phase1_result, url, article_content, today)
      article_summary = article_content[0, 1000]
      article_summary += "...(以下省略)" if article_content.length > 1000

      phase2_body = @prompts.render("phase2",
                                    "Phase1で出力された主題" => "Phase1の出力を参照",
                                    "Phase1で出力されたユーザー意図" => "Phase1の出力を参照",
                                    "Phase1で出力された情報の種類" => "Phase1の出力を参照",
                                    "Phase1で出力された視点" => "Phase1の出力を参照",
                                    "Phase1で出力された情報源" => "Phase1の出力を参照",
                                    "元記事のタイトルとURL" => url,
                                    "元記事の要約または抜粋" => article_summary)

      prompt = @prompts.render("phase2_wrapper",
                               "Phase1の出力" => phase1_result,
                               "Phase2の指示" => phase2_body,
                               "今日の日付" => today)

      response = call_gemini(client, prompt, google_search: true, model: PHASE2_MODEL)

      if response.grounded?
        @logger.info "グラウンディング検索が使用されました（検索結果 #{response.grounding_chunks.length}件）"
      else
        @logger.warn "グラウンディング検索が使用されませんでした"
        transcript "groundingMetadata: #{response.grounding_metadata.inspect}"
      end

      response
    end

    # Phase 2.5: グラウンディング引用のリダイレクトURLを実URLに解決する
    def extract_and_resolve_grounding_urls(phase2_response)
      unless phase2_response.grounded?
        @logger.warn "グラウンディング検索が使用されなかったため、解決するURLがありません"
        transcript "Warning: Grounding search was not used."
        return []
      end

      chunks = phase2_response.grounding_chunks
      transcript "Grounding Chunks: #{chunks.length}"

      grounding_urls = []
      chunks.each_with_index do |chunk, idx|
        next unless chunk["web"]

        vertex_url = chunk["web"]["uri"]
        title = chunk["web"]["title"]
        transcript "Chunk #{idx + 1}: #{title} (#{vertex_url})"

        final_url = UrlResolver.follow_redirect(vertex_url, logger: @logger)

        if final_url && !final_url.include?("vertexaisearch.cloud.google.com")
          @logger.info "  URL解決 #{idx + 1}/#{chunks.length}: #{final_url}"
          transcript "  -> Redirected to: #{final_url}"
          grounding_urls << final_url
        else
          @logger.warn "  URL解決 #{idx + 1}/#{chunks.length}: 失敗（#{title}）"
          transcript "  -> Failed to resolve redirect"
        end

        # レート制限対策
        sleep(0.5) if idx < chunks.length - 1
      end

      @logger.info "URL解決結果: 成功 #{grounding_urls.size}件 / 失敗 #{chunks.length - grounding_urls.size}件"
      grounding_urls.uniq
    end

    def execute_phase3(client, phase2_result, verified_urls, news_context)
      prompt = @prompts.render("phase3_wrapper",
                               "調査レポート" => phase2_result,
                               "検証済みURL一覧" => JSON.pretty_generate(verified_urls),
                               "Phase3の指示" => @prompts.read("phase3")) + news_context

      response = call_gemini(client, prompt, response_schema: timeline_schema)
      raise GenerationError, "Phase 3のJSON出力に失敗しました" unless response.json?

      response.json
    end

    def execute_phase3_5(client, phase2_result, phase3_result, verified_urls, news_context)
      prompt = @prompts.render("phase3_5_wrapper",
                               "調査レポート" => phase2_result,
                               "Phase3のタイムラインJSON" => JSON.pretty_generate(phase3_result),
                               "検証済みURL一覧" => JSON.pretty_generate(verified_urls),
                               "Phase3.5の指示" => @prompts.read("phase3_5")) + news_context

      response = call_gemini(client, prompt, response_schema: timeline_schema)
      raise GenerationError, "Phase 3.5のJSON出力に失敗しました" unless response.json?

      response.json
    end

    def timeline_schema
      {
        type: "OBJECT",
        properties: {
          "title" => { type: "STRING", description: "タイムライン記事のタイトル" },
          "description" => { type: "STRING", description: "タイムライン記事の概要" },
          "blocks" => {
            type: "ARRAY",
            description: "タイムラインブロックの配列",
            items: {
              type: "OBJECT",
              properties: {
                "event_year" => { type: "INTEGER", description: "出来事の年" },
                "event_month" => { type: "INTEGER", description: "出来事の月" },
                "event_day" => { type: "INTEGER", description: "出来事の日（不明な場合はnull）" },
                "title" => { type: "STRING", description: "ブロックのタイトル・見出し" },
                "content" => { type: "STRING", description: "ブロックの本文" },
                "evidence_source_urls" => {
                  type: "ARRAY",
                  description: "情報源の完全なURL。【重要】Phase2レポートの最後にある「実際の情報源URL一覧」セクションに記載されているURLから必ず選んでください。絶対に自分でURLを作成・推測しないでください。",
                  items: { type: "STRING", description: "完全なURL（https://で始まる形式）。必ずPhase2の「実際の情報源URL一覧」に記載されているURLをそのままコピーしてください。" }
                }
              },
              required: %w[event_year event_month title content evidence_source_urls]
            }
          }
        },
        required: %w[title description blocks]
      }
    end

    def phase0_response_schema
      {
        type: "OBJECT",
        properties: {
          content_appropriate: { type: "STRING", description: "コンテンツ適切性: 適切 / 不適切" },
          content_appropriate_reason: { type: "STRING", description: "コンテンツ適切性評価の理由" },
          timelineable: { type: "STRING", description: "タイムライン化可能性: 可能 / 困難 / 不可能" },
          timelineable_reason: { type: "STRING", description: "タイムライン化可能性評価の理由" },
          relevance: { type: "STRING", description: "関連性の評価（参考情報）: 高い / 中程度 / 低い / なし" },
          relevance_reason: { type: "STRING", description: "関連性評価の理由" },
          user_intent_summary: { type: "STRING", description: "ユーザー意図の要約（簡潔に）" },
          suggestions: {
            type: "ARRAY",
            description: "ニュースに適した観点の提案",
            items: { type: "STRING" }
          }
        },
        required: %w[
          content_appropriate content_appropriate_reason
          timelineable timelineable_reason
          relevance relevance_reason
          user_intent_summary suggestions
        ]
      }
    end

    def inappropriate_content_message(result)
      <<~MESSAGE
        ユーザー意図がニュースプラットフォームに適していません。

        ユーザー意図: #{result[:user_intent_summary]}

        理由: #{result[:content_appropriate_reason]}

        ニュースに適した内容（社会的な出来事の歴史や変遷、産業・技術の発展など）を指定してください。
      MESSAGE
    end

    def not_timelineable_message(result)
      <<~MESSAGE
        ユーザー意図をタイムライン化できません。

        ユーザー意図: #{result[:user_intent_summary]}

        理由: #{result[:timelineable_reason]}

        時系列で追跡可能な観点を指定してください。
      MESSAGE
    end

    def measure_time(label)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      message = "[Time] #{label}: #{duration.round(2)}s"
      @logger.info message
      transcript message

      result
    end

    def transcript_header(url, user_intent)
      transcript "# News Timeline Generation Log"
      transcript "Date: #{Time.now}"
      transcript "URL: #{url}"
      transcript "User Intent: #{user_intent}"
      transcript "Model: #{@model}"
      transcript "-" * 50
    end

    def transcript(message)
      @transcript << "#{message}\n"
    end

    # transcript_path指定時のみ、全プロンプト・レスポンスを含むログを書き出す
    def write_transcript
      return unless @transcript_path

      File.write(@transcript_path, @transcript)
    rescue StandardError => e
      @logger.error "トランスクリプト保存エラー: #{e.message}"
    end
  end
end
